import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../editor/block.dart';
import '../models/note.dart';
import '../models/note_settings.dart';
import '../security/security_service.dart';
import '../util/date_format.dart';
import 'note_store.dart';
import 'search_index.dart';

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

  /// `_notes` 的版本号：列表数据一变就 +1，作为 [visibleNotes] 缓存依据。
  int _notesRevision = 0;

  /// [visibleNotes] 的一次性缓存。
  ///
  /// 首页每次 rebuild 都会读一次，锁定计时、搜索计数也会读；没有缓存时
  /// 几千条笔记会「每帧全量 where + sort」。这里按
  /// 「数据版本 + 标签 + 搜索词 + 排序」做 key，命中就直接返回同一实例。
  List<Note>? _visibleCache;
  int _visibleCacheRevision = -1;
  String? _visibleCacheTag;
  String _visibleCacheKeyword = '';
  SortOrder? _visibleCacheSort;

  /// 全文搜索索引；原生 SQLite 不可用时为 null（回退到线性扫描）。
  SearchIndex? _index;

  /// 当前搜索词命中的笔记 id；null 表示「没有走索引」。
  Set<String>? _searchHits;
  String _searchHitsQuery = '';

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
    final SortOrder sortOrder = _settings.sortOrder;

    final List<Note>? cached = _visibleCache;
    if (cached != null &&
        _visibleCacheRevision == _notesRevision &&
        _visibleCacheTag == tag &&
        _visibleCacheKeyword == keyword &&
        _visibleCacheSort == sortOrder) {
      return cached;
    }

    final Set<String>? hits = keyword.isEmpty ? null : _searchIds(keyword);

    final result = _notes.where((note) {
      if (tag != null && !note.tags.contains(tag)) {
        return false;
      }
      if (keyword.isEmpty) {
        return true;
      }
      // 锁定笔记的正文不在内存里（列表里只剩空串），也不进索引 ——
      // 正文内容不该被搜出来，也不该出现在结果里。
      if (note.locked) {
        return false;
      }
      if (hits != null) {
        return hits.contains(note.id);
      }
      // 索引不可用时的兜底：保持原有线性匹配语义。
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
      final int byTime;
      switch (sortOrder) {
        case SortOrder.updated:
          byTime = b.updated.compareTo(a.updated);
        case SortOrder.created:
          byTime = b.created.compareTo(a.created);
      }
      if (byTime != 0) {
        return byTime;
      }
      // 时间戳相同的笔记（同一批导入、同一次保存）按 id 兜底：Dart 的
      // List.sort 不稳定，没有 tie-breaker 时刷新一次顺序就可能变。
      return a.id.compareTo(b.id);
    });

    _visibleCache = result;
    _visibleCacheRevision = _notesRevision;
    _visibleCacheTag = tag;
    _visibleCacheKeyword = keyword;
    _visibleCacheSort = sortOrder;
    return result;
  }

  Future<void> load() async {
    _loading = true;
    notifyListeners();
    final loaded = await _store.loadNotes();
    _settings = await _store.loadSettings();
    _notes = loaded;
    _notesRevision++;
    _loading = false;
    _rebuildSearchIndex();
    notifyListeners();
  }

  /// 确保索引存在并与内存里的笔记一致。
  ///
  /// 索引是派生数据：打不开（原生库缺失/文件损坏）就静默降级为线性搜索；
  /// 对账只重建 `updated` 变化的条目，几千条笔记也是毫秒级。
  void _rebuildSearchIndex() {
    _index ??= SearchIndex.tryOpen(_store.searchIndexPath);
    _searchHits = null;
    _searchHitsQuery = '';
    try {
      _index?.reconcile(_notes);
    } catch (_) {
      // 索引写失败（磁盘满等）不影响笔记本身，搜索退回线性扫描。
      _index?.close();
      _index = null;
    }
  }

  /// 取当前搜索词的命中集合（按词缓存，避免每帧重复查库）。
  Set<String>? _searchIds(String keyword) {
    final index = _index;
    if (index == null) {
      return null;
    }
    if (_searchHits != null && _searchHitsQuery == keyword) {
      return _searchHits;
    }
    _searchHits = index.search(keyword);
    _searchHitsQuery = keyword;
    return _searchHits;
  }

  /// 内存与索引都失效的时机（保存 / 删除 / 批量改标签）。
  void _invalidateSearchCache() {
    _searchHits = null;
    _searchHitsQuery = '';
  }

  /// 最近一次自动备份失败的原因（成功时清空）。
  ///
  /// 只在内存里记，不持久化：下次启动会重新尝试；设置页据此显示
  /// 「上次备份失败，点此重试」，避免备份坏了用户却不知道。
  String? _lastBackupError;
  String? get lastBackupError => _lastBackupError;

  /// 最近一次外置备份失败的原因（成功时清空）。
  String? _lastExternalBackupError;
  String? get lastExternalBackupError => _lastExternalBackupError;

  /// 最近一次外置备份成功的时间（未开启/从未成功时为 null）。
  DateTime? get lastExternalBackupTime =>
      DateTime.tryParse(_settings.lastExternalBackupAt ?? '');

  /// 外置备份是否正在跑：设置页据此禁用重复点击。
  bool _externalBackupRunning = false;
  bool get externalBackupRunning => _externalBackupRunning;

  /// 上次尝试外置备份的时间（无论成败）。
  ///
  /// 目录被删/授权失效时，失败不会写 `lastExternalBackupAt`；没有这个节流，
  /// 用户每次回前台都会重新打一遍全量 zip。失败后 1 小时内不再自动重试，
  /// 手动「立即导出」不受限。
  DateTime? _lastExternalAttempt;

  /// 把导出包写进用户授权的外置目录；[force] 为 false 时不足 24 小时会跳过。
  ///
  /// 返回本次备份时间；未开启、跳过或失败（见 [lastExternalBackupError]）返回 null。
  Future<DateTime?> runExternalBackup({bool force = false}) async {
    final String? treeUri = _settings.externalBackupUri;
    if (treeUri == null || _externalBackupRunning) {
      return null;
    }
    final DateTime now = DateTime.now();
    final DateTime? lastAttempt = _lastExternalAttempt;
    if (!force &&
        lastAttempt != null &&
        now.difference(lastAttempt) < const Duration(hours: 1)) {
      return null;
    }
    _lastExternalAttempt = now;
    _externalBackupRunning = true;
    notifyListeners();
    try {
      // 加密外置备份：口令以 Keystore 密文存在 settings 里，这里临时解开。
      // 换机后 Keystore 不同、或用户清过数据，解不开就明确报错，
      // 绝不悄悄退化成明文备份。
      String? password;
      if (_settings.backupEncrypted) {
        final String? sealed = _settings.backupPasswordSealed;
        if (sealed == null) {
          _lastExternalBackupError = '未设置备份口令，请在「备份与恢复」里重新开启加密';
          notifyListeners();
          return null;
        }
        try {
          password = await const SecurityService().openText(sealed);
        } catch (_) {
          _lastExternalBackupError = '无法读取本机备份口令，请重新设置';
          notifyListeners();
          return null;
        }
      }
      final DateTime? at = await _store.ensureExternalBackup(
        treeUri: treeUri,
        lastAt: lastExternalBackupTime,
        force: force,
        password: password,
      );
      if (at != null) {
        // 记下成功时间，避免下次回前台又重打一遍。
        await updateSettings(
          _settings.copyWith(lastExternalBackupAt: at.toIso8601String()),
        );
      }
      if (_lastExternalBackupError != null) {
        _lastExternalBackupError = null;
        notifyListeners();
      }
      return at;
    } catch (error) {
      // 授权失效、目录被删、磁盘满：都要让用户看到并能重新选择。
      _lastExternalBackupError = '$error';
      notifyListeners();
      return null;
    } finally {
      _externalBackupRunning = false;
      notifyListeners();
    }
  }

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
      // 外置备份（用户开启了才有）：失败原因记录在
      // [lastExternalBackupError]，设置页显示「上次失败，点此重试」。
      if (_settings.externalBackupUri != null) {
        await runExternalBackup();
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
  Future<void> upsert(Note note, {bool keepHistory = true}) async {
    await _store.saveNote(note, keepHistory: keepHistory);
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
    _notesRevision++;
    // 索引里存的是正文分词，锁定笔记会被移除。
    _index?.upsertNote(stored);
    _invalidateSearchCache();
    notifyListeners();
  }

  Future<void> remove(Note note) async {
    await _store.deleteNote(note);
    _notes = _notes.where((item) => item.id != note.id).toList();
    _notesRevision++;
    _index?.removeNote(note.id);
    _invalidateSearchCache();
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

  /// 存储占用统计（设置页「存储空间」用）。
  Future<StorageUsage> measureStorage() => _store.measureStorage();

  /// 清理没有被任何笔记引用的附件文件。
  Future<OrphanCleanupResult> cleanUnusedAssets() =>
      _store.cleanUnusedAssets();

  /// 导入外部 Markdown 文件，写入后刷新列表与搜索索引。
  Future<MarkdownImportResult> importMarkdownFiles(
    Iterable<String> paths,
  ) async {
    final result = await _store.importMarkdownFiles(paths);
    await load();
    return result;
  }

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

  /// 置顶 / 取消置顶只翻转 `pinned`，不动 `updated`。
  ///
  /// 旧实现会顺手把 `updated` 刷成 now：置顶后笔记跳到置顶组第一位，
  /// 取消置顶又跳到普通列表最前，列表里时间还变成「刚刚」——置顶只是
  /// 一种收纳操作，不该被当成内容更新（会污染「最近更新」排序）。
  Future<Note> togglePin(Note note) async {
    final updated = note.copyWith(pinned: !note.pinned);
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
      await _store.saveNote(next[index], keepHistory: false);
      _index?.upsertNote(next[index]);
    }
    _notes = next;
    _invalidateSearchCache();
    if (_activeTag == tag) {
      _activeTag = null;
    }
    notifyListeners();
    return affected.length;
  }

  /// 标签 → 笔记数（标签管理页展示用）。按名称排序，页面自己决定顺序。
  Map<String, int> get tagCounts {
    final counter = <String, int>{};
    for (final note in _notes) {
      for (final tag in note.tags) {
        counter[tag] = (counter[tag] ?? 0) + 1;
      }
    }
    return counter;
  }

  /// 把某个标签改名到所有笔记（已存在同名标签时自动去重）。
  ///
  /// 与 [deleteTag] 一样只动 frontmatter，不刷新 `updated`。
  Future<int> renameTag(String from, String to) async {
    final String? target = Note.normalizeTag(to);
    if (target == null || target == from) {
      return 0;
    }
    final affected = _notes
        .where((Note note) => note.tags.contains(from))
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
      final tags = note.tags
          .map((String item) => item == from ? target : item)
          .toSet()
          .toList();
      next[index] = note.copyWith(tags: tags);
      await _store.saveNote(next[index], keepHistory: false);
      _index?.upsertNote(next[index]);
    }
    _notes = next;
    _invalidateSearchCache();
    if (_activeTag == from) {
      _activeTag = target;
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
