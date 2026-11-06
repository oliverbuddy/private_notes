import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../models/note.dart';

/// 全文搜索索引（SQLite FTS5）。
///
/// 为什么不用「扫一遍正文 contains」：笔记到几千条后，每次输入都要把
/// 所有正文拼成小写再匹配，主线程会被拖住。这里把正文预先切成中文
/// 一元 + 二元组写进 FTS5，查询走倒排索引，和笔记总量基本无关。
///
/// 中文为什么要自己切词：FTS5 的 unicode61 分词器按空格/标点切，一整句
/// 中文会被当成一个 token。切成「单字 + 相邻二字」后：
///  - 单字能命中（查「记」）；
///  - 二字组保证相邻（查「小记」不会命中「小…记」）。
///
/// 索引文件放在 `Xiaoji/index/`，属于派生数据：
///  - 不进备份/导出（里面有正文分词后的明文）；
///  - 损坏或版本变化时直接删掉重建，不用迁移。
class SearchIndex {
  SearchIndex._(this._db);

  final Database _db;

  /// 索引库版本：分词规则变了就换文件名，旧库自然作废。
  static const int schemaVersion = 1;

  /// 打开（必要时创建）索引；原生库不可用时返回 null，调用方回退到线性搜索。
  ///
  /// 测试环境（Dart VM / 无 sqlite 原生库）会走到 null 分支，这样搜索
  /// 仍然能工作，只是慢一点 —— 不能因为索引打不开就让 App 起不来。
  static SearchIndex? tryOpen(String path) {
    try {
      Directory(File(path).parent.path).createSync(recursive: true);
      final db = sqlite3.open(path);
      db.execute('PRAGMA journal_mode = WAL');
      db.execute('PRAGMA synchronous = NORMAL');
      db.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
          id UNINDEXED,
          body,
          tags,
          tokenize = 'unicode61'
        )
      ''');
      db.execute('''
        CREATE TABLE IF NOT EXISTS notes_meta(
          id TEXT PRIMARY KEY,
          updated TEXT NOT NULL
        )
      ''');
      return SearchIndex._(db);
    } catch (_) {
      // 原生库缺失 / 文件损坏：回退到线性搜索即可，不影响使用。
      return null;
    }
  }

  void close() {
    try {
      _db.close();
    } catch (_) {
      // 关闭失败不影响退出。
    }
  }

  // ---------------------------------------------------------------------------
  // 分词
  // ---------------------------------------------------------------------------

  /// 把用户输入切成查询 token（与文档分词同一套规则）。
  static List<String> tokensOf(String text) {
    final out = <String>{};
    final cjk = StringBuffer();
    final word = StringBuffer();

    void flushCjk() {
      if (cjk.isEmpty) {
        return;
      }
      final run = cjk.toString();
      cjk.clear();
      for (var i = 0; i < run.length; i++) {
        out.add(run[i]);
        if (i + 1 < run.length) {
          out.add(run.substring(i, i + 2));
        }
      }
    }

    void flushWord() {
      if (word.isEmpty) {
        return;
      }
      out.add(word.toString().toLowerCase());
      word.clear();
    }

    for (final int rune in text.runes) {
      if (_isCjk(rune)) {
        flushWord();
        cjk.writeCharCode(rune);
      } else if (_isWordRune(rune)) {
        flushCjk();
        word.writeCharCode(rune);
      } else {
        flushCjk();
        flushWord();
      }
    }
    flushCjk();
    flushWord();
    return out.toList();
  }

  /// 文档侧：token 用空格拼起来，交给 unicode61 当普通词处理。
  static String tokenizeDocument(String text) => tokensOf(text).join(' ');

  static bool _isCjk(int rune) {
    return (rune >= 0x4E00 && rune <= 0x9FFF) || // 基本汉字
        (rune >= 0x3400 && rune <= 0x4DBF) || // 扩展 A
        (rune >= 0xF900 && rune <= 0xFAFF) || // 兼容汉字
        (rune >= 0x3040 && rune <= 0x30FF); // 日文假名
  }

  static bool _isWordRune(int rune) {
    if ((rune >= 0x30 && rune <= 0x39) || // 0-9
        (rune >= 0x41 && rune <= 0x5A) || // A-Z
        (rune >= 0x61 && rune <= 0x7A)) {
      // a-z
      return true;
    }
    // 带音标的拉丁字母（café、über）。不能笼统写 rune >= 0x80：
    // 那样中文逗号、句号也会被当成词，索引里会多出一堆标点 token。
    return rune >= 0xC0 &&
        rune <= 0x24F &&
        rune != 0xD7 && // ×
        rune != 0xF7; // ÷
  }

  /// 拼 FTS5 查询表达式：所有 token 取交集，英文词做前缀匹配。
  static String matchExpression(String query) {
    final List<String> tokens = tokensOf(query);
    if (tokens.isEmpty) {
      return '';
    }
    final parts = <String>[];
    for (final token in tokens) {
      final isAscii = token.codeUnits.every((int c) => c < 0x80);
      final escaped = token.replaceAll('"', '""');
      parts.add(isAscii ? '"$escaped"*' : '"$escaped"');
    }
    return parts.join(' AND ');
  }

  // ---------------------------------------------------------------------------
  // 写入
  // ---------------------------------------------------------------------------

  /// 全量对账：索引与磁盘笔记保持一致的唯一入口。
  ///
  /// 只重建 `updated` 变化的条目；锁定笔记从索引里移除（正文在索引里
  /// 是明文，不能留）。
  void reconcile(List<Note> notes) {
    final Map<String, String> indexed = <String, String>{};
    for (final Row row in _db.select('SELECT id, updated FROM notes_meta')) {
      indexed[row['id'] as String] = row['updated'] as String;
    }
    final Set<String> live = <String>{};
    _db.execute('BEGIN');
    try {
      for (final Note note in notes) {
        live.add(note.id);
        if (note.locked) {
          if (indexed.containsKey(note.id)) {
            _delete(note.id);
          }
          continue;
        }
        final String stamp = note.updated.toIso8601String();
        if (indexed[note.id] == stamp) {
          continue;
        }
        _insert(note, stamp);
      }
      for (final String id in indexed.keys) {
        if (!live.contains(id)) {
          _delete(id);
        }
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 单条更新（保存/改标签时调用）。
  void upsertNote(Note note) {
    if (note.locked) {
      removeNote(note.id);
      return;
    }
    _insert(note, note.updated.toIso8601String());
  }

  void removeNote(String id) {
    _delete(id);
  }

  void _insert(Note note, String stamp) {
    _db.execute('DELETE FROM notes_fts WHERE id = ?', <Object?>[note.id]);
    _db.execute(
      'INSERT INTO notes_fts(id, body, tags) VALUES (?, ?, ?)',
      <Object?>[
        note.id,
        tokenizeDocument(note.body),
        tokenizeDocument(note.tags.join(' ')),
      ],
    );
    _db.execute(
      'INSERT INTO notes_meta(id, updated) VALUES (?, ?) '
      'ON CONFLICT(id) DO UPDATE SET updated = excluded.updated',
      <Object?>[note.id, stamp],
    );
  }

  void _delete(String id) {
    _db.execute('DELETE FROM notes_fts WHERE id = ?', <Object?>[id]);
    _db.execute('DELETE FROM notes_meta WHERE id = ?', <Object?>[id]);
  }

  // ---------------------------------------------------------------------------
  // 查询
  // ---------------------------------------------------------------------------

  /// 返回命中笔记 id；查询为空或索引异常时返回空集合。
  Set<String> search(String query) {
    final String expression = matchExpression(query);
    if (expression.isEmpty) {
      return <String>{};
    }
    try {
      final ResultSet rows = _db.select(
        'SELECT id FROM notes_fts WHERE notes_fts MATCH ?',
        <Object?>[expression],
      );
      return rows.map((Row row) => row['id'] as String).toSet();
    } on SqliteException {
      // 用户输入可能拼出非法表达式（极端符号组合）：当成无结果，
      // 不能让搜索框输错一个字符就抛异常。
      return <String>{};
    }
  }
}
