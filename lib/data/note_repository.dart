import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../editor/block.dart';
import '../models/note.dart';
import '../models/note_settings.dart';
import '../util/date_format.dart';
import 'note_store.dart';

/// 笔记的内存视图。
///
/// 没用 riverpod/provider：这里只有列表、筛选、搜索三个状态，
/// `ChangeNotifier` + `ListenableBuilder` 足够，也少一个必须跟着升级的依赖。
class NoteRepository extends ChangeNotifier {
  NoteRepository(this._store);

  final NoteStore _store;

  NoteStore get store => _store;

  List<Note> _notes = const <Note>[];
  NoteSettings _settings = const NoteSettings();
  bool _loading = true;
  String _query = '';
  String? _activeTag;

  bool get isLoading => _loading;

  NoteSettings get settings => _settings;

  String get query => _query;

  String? get activeTag => _activeTag;

  bool get isSearching => _query.trim().isNotEmpty;

  /// 全部笔记（未排序）。
  List<Note> get notes => List<Note>.unmodifiable(_notes);

  /// 标签云：按出现次数降序，次数相同按名称排，保证筛选条顺序稳定。
  List<String> get tags {
    final counter = <String, int>{};
    for (final note in _notes) {
      for (final tag in note.tags) {
        counter[tag] = (counter[tag] ?? 0) + 1;
      }
    }
    final names = counter.keys.toList();
    names.sort((a, b) {
      final diff = counter[b]!.compareTo(counter[a]!);
      if (diff != 0) {
        return diff;
      }
      return a.compareTo(b);
    });
    return names;
  }

  /// 当前标签 + 搜索词过滤后的结果，置顶优先，其余按 updated 倒序。
  List<Note> get visibleNotes {
    final keyword = _query.trim().toLowerCase();
    final tag = _activeTag;

    final result = _notes.where((note) {
      if (tag != null && !note.tags.contains(tag)) {
        return false;
      }
      if (keyword.isEmpty) {
        return true;
      }
      // 锁定笔记的正文不在内存里（列表里只剩空串），搜索命中只会来自
      // 标签 —— 正文内容不该被搜出来，也不该出现在结果里。
      if (note.locked) {
        return false;
      }
      if (note.body.toLowerCase().contains(keyword)) {
        return true;
      }
      if (note.tags.any((item) => item.toLowerCase().contains(keyword))) {
        return true;
      }
      return plainSummary(note.body).toLowerCase().contains(keyword);
    }).toList();

    result.sort((a, b) {
      if (a.pinned != b.pinned) {
        return a.pinned ? -1 : 1;
      }
      return b.updated.compareTo(a.updated);
    });
    return result;
  }

  Future<void> load() async {
    _loading = true;
    notifyListeners();
    final loaded = await _store.loadNotes();
    _settings = await _store.loadSettings();
    _notes = loaded;
    _loading = false;
    notifyListeners();
  }

  /// 最近一次自动备份失败的原因（成功时清空）。
  ///
  /// 只在内存里记，不持久化：下次启动会重新尝试；设置页据此显示
  /// 「上次备份失败，点此重试」，避免备份坏了用户却不知道。
  String? _lastBackupError;
  String? get lastBackupError => _lastBackupError;

  /// 防止「启动 + 回前台」短时间内并发跑维护（两个备份写同一目录）。
  bool _maintenanceRunning = false;

  /// 启动 / 回到前台时跑的后台维护：清理超期回收站、临时文件、自动备份。
  ///
  /// 刻意不放进 [load]：`load` 在测试里被大量调用，后台任务会和临时目录
  /// 的创建/删除抢跑。自动备份按「距上次 ≥24 小时」判断（见
  /// [NoteStore.ensureAutoBackup]），所以回前台重复调用是幂等的。
  Future<void> runMaintenance() async {
    if (_maintenanceRunning) {
      return;
    }
    _maintenanceRunning = true;
    try {
      try {
        await _store.purgeExpiredTrash();
      } catch (_) {
        // 清理失败不影响使用，下次再试。
      }
      try {
        await _store.cleanTempDir();
      } catch (_) {
        // 临时文件清理失败忽略，不影响笔记数据。
      }
      try {
        await _store.ensureAutoBackup();
        if (_lastBackupError != null) {
          _lastBackupError = null;
          notifyListeners();
        }
      } catch (_) {
        // 自动备份失败要能被用户看到，但不影响 App 正常使用。
        _lastBackupError = '自动备份失败';
        notifyListeners();
      }
    } finally {
      _maintenanceRunning = false;
    }
  }

  void setQuery(String value) {
    if (_query == value) {
      return;
    }
    _query = value;
    notifyListeners();
  }

  void setActiveTag(String? tag) {
    if (_activeTag == tag) {
      return;
    }
    _activeTag = tag;
    notifyListeners();
  }

  /// 新增或更新。落盘成功后才更新内存，避免出现「界面有、磁盘没有」的假象。
  Future<void> upsert(Note note) async {
    await _store.saveNote(note);
    // 锁定笔记的明文只留在当前编辑页：列表/搜索拿到的永远是没有正文的
    // 副本，避免首页摘要或标签云把锁定内容带出来。
    final stored = note.locked ? note.copyWith(body: '') : note;
    final index = _notes.indexWhere((item) => item.id == note.id);
    final next = <Note>[..._notes];
    if (index >= 0) {
      next[index] = stored;
    } else {
      next.add(stored);
    }
    _notes = next;
    notifyListeners();
  }

  Future<void> remove(Note note) async {
    await _store.deleteNote(note);
    _notes = _notes.where((item) => item.id != note.id).toList();
    notifyListeners();
  }

  /// 回收站列表（按删除时间倒序）。
  Future<List<TrashedNote>> loadTrash() => _store.listTrash();

  /// 从回收站恢复并刷新列表。
  Future<Note?> restoreFromTrash(TrashedNote trashed) async {
    final note = await _store.restoreFromTrash(trashed);
    await load();
    return note;
  }

  /// 删除后撤销：按 id 找回最近一条回收站记录。
  Future<bool> undoDelete(String noteId) async {
    final trashed = await _store.restoreTrashById(noteId);
    if (trashed == null) {
      return false;
    }
    await load();
    return true;
  }

  Future<void> purgeTrash(TrashedNote trashed) => _store.purgeTrash(trashed);

  Future<void> purgeAllTrash() => _store.purgeAllTrash();

  Future<DateTime?> lastBackupTime() => _store.lastBackupTime();

  /// 应用私有目录里的备份列表（设置页「从备份恢复」用）。
  Future<List<BackupEntry>> listBackups() => _store.listBackups();

  /// 立即生成一份应用私有备份（设置页「立即备份」）。
  Future<File> createBackupNow() async {
    final stamp = formatExportStamp(DateTime.now());
    final File file =
        await _store.createBackupFile(name: 'manual-$stamp.zip');
    // 手动备份成功同样说明备份链路是通的，清掉「上次失败」状态。
    if (_lastBackupError != null) {
      _lastBackupError = null;
      notifyListeners();
    }
    return file;
  }

  Future<Note> togglePin(Note note) async {
    final updated = note.copyWith(
      pinned: !note.pinned,
      updated: DateTime.now(),
    );
    await upsert(updated);
    return updated;
  }

  /// 从所有笔记里移除某个标签，返回受影响的笔记数量。
  ///
  /// 只动 frontmatter 的 tags，不改正文，也不刷新 `updated`：
  /// 整理标签不该把一堆笔记顶到列表最前面。
  Future<int> deleteTag(String tag) async {
    final affected = _notes
        .where((Note note) => note.tags.contains(tag))
        .toList(growable: false);
    if (affected.isEmpty) {
      return 0;
    }
    final next = <Note>[..._notes];
    for (final note in affected) {
      final index = next.indexWhere((Note item) => item.id == note.id);
      if (index < 0) {
        continue;
      }
      next[index] = note.copyWith(
        tags: note.tags.where((String item) => item != tag).toList(),
      );
      await _store.saveNote(next[index]);
    }
    _notes = next;
    if (_activeTag == tag) {
      _activeTag = null;
    }
    notifyListeners();
    return affected.length;
  }

  Future<void> updateSettings(NoteSettings next) async {
    if (next == _settings) {
      return;
    }
    _settings = next;
    notifyListeners();
    await _store.saveSettings(next);
  }

  Future<String> exportAll() => _store.exportAll();

  /// 从导出 zip 恢复（设置页「恢复备份」入口），恢复后重载内存列表。
  Future<(int, int)> restoreFromZip(Uint8List bytes) async {
    final result = await _store.restoreFromZip(bytes);
    await load();
    return result;
  }

  /// 从文件路径恢复（设置页主通道，原生流式解压，不占内存）。
  Future<(int, int)> restoreFromZipFile(String path) async {
    final result = await _store.restoreFromZipFile(path);
    await load();
    return result;
  }
}
