import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/data/search_index.dart';
import 'package:xiaoji/models/note.dart';

/// 搜索索引回归：中文分词、FTS5 命中、增量更新、锁定笔记不进索引。
///
/// 索引依赖原生 SQLite；测试环境如果加载不到会 `tryOpen` 返回 null，
/// 此时仓库会自动退回线性搜索（仍应通过），索引本身的用例会跳过。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('分词', () {
    test('中文切成一元 + 二元组，英文按词', () {
      final tokens = SearchIndex.tokensOf('小记 hello');
      expect(tokens, contains('小'));
      expect(tokens, contains('记'));
      expect(tokens, contains('小记'));
      expect(tokens, contains('hello'));
    });

    test('标点与空白不产生 token', () {
      final tokens = SearchIndex.tokensOf('，。！ \n\t');
      expect(tokens, isEmpty);
    });

    test('查询表达式对所有 token 取交集，英文做前缀', () {
      final expression = SearchIndex.matchExpression('小记 note');
      expect(expression, contains('"小记"'));
      expect(expression, contains('"note"*'));
      expect(expression, contains('AND'));
    });
  });

  group('FTS5 索引', () {
    late Directory tempDir;
    late SearchIndex index;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('xiaoji_index_');
      final opened = SearchIndex.tryOpen('${tempDir.path}/search.db');
      if (opened == null) {
        // 没有原生 SQLite：该用例无意义，直接跳过（仓库侧已有线性兜底）。
        return;
      }
      index = opened;
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Note note(String id, String body, {DateTime? updated, bool locked = false}) {
      return Note(
        id: id,
        created: DateTime(2026, 11, 6, 10),
        updated: updated ?? DateTime(2026, 11, 6, 10),
        body: body,
        locked: locked,
      );
    }

    test('中文单字与二字词都能命中', () {
      index.reconcile(<Note>[
        note('a', '今天去公园散步'),
        note('b', '明天整理备份链路'),
      ]);

      expect(index.search('散'), contains('a'));
      expect(index.search('散步'), contains('a'));
      expect(index.search('备份'), contains('b'));
      expect(index.search('散备'), isEmpty, reason: '不连续的二字不该命中');
    });

    test('英文大小写不敏感且支持前缀', () {
      index.reconcile(<Note>[note('a', 'Flutter Markdown 笔记')]);
      expect(index.search('flutter'), contains('a'));
      expect(index.search('FLUT'), contains('a'));
    });

    test('更新正文后旧词不再命中', () {
      index.reconcile(<Note>[note('a', '旧内容')]);
      expect(index.search('旧内容'), contains('a'));

      index.upsertNote(
        note('a', '新内容', updated: DateTime(2026, 11, 6, 11)),
      );
      expect(index.search('新内容'), contains('a'));
      expect(index.search('旧内容'), isEmpty);
    });

    test('锁定笔记不进入索引', () {
      index.reconcile(<Note>[note('a', '机密内容', locked: true)]);
      expect(index.search('机密'), isEmpty);
    });

    test('删除的笔记从索引里消失', () {
      index.reconcile(<Note>[note('a', '会被删掉'), note('b', '保留')]);
      index.removeNote('a');
      expect(index.search('删掉'), isEmpty);
      expect(index.search('保留'), contains('b'));
    });
  });

  group('仓库搜索', () {
    late Directory tempDir;
    late NoteRepository repository;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('xiaoji_repo_search_');
      final store = await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
      repository = NoteRepository(store);
      await repository.load();
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('搜索命中正文与标签，锁定笔记被排除', () async {
      await repository.upsert(Note(
        id: 's1',
        created: DateTime(2026, 11, 6, 9),
        updated: DateTime(2026, 11, 6, 9),
        tags: const <String>['旅行'],
        body: '周末去爬山',
      ));
      await repository.upsert(Note(
        id: 's2',
        created: DateTime(2026, 11, 6, 9),
        updated: DateTime(2026, 11, 6, 9),
        body: '爬山路线要带水',
      ));

      repository.setQuery('爬山');
      expect(
        repository.visibleNotes.map((Note n) => n.id).toSet(),
        <String>{'s1', 's2'},
      );

      repository.setQuery('旅行');
      expect(repository.visibleNotes.single.id, 's1');

      repository.setQuery('');
      expect(repository.visibleNotes.length, 2);
    });

    test('删除后搜索结果同步更新', () async {
      final note = Note(
        id: 's3',
        created: DateTime(2026, 11, 6, 9),
        updated: DateTime(2026, 11, 6, 9),
        body: '待删除的关键词',
      );
      await repository.upsert(note);
      repository.setQuery('关键词');
      expect(repository.visibleNotes, hasLength(1));

      await repository.remove(note);
      expect(repository.visibleNotes, isEmpty);
    });
  });
}
