import 'package:flutter/foundation.dart';

import '../editor/block.dart';
import '../models/note.dart';
import '../models/note_settings.dart';
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
    final index = _notes.indexWhere((item) => item.id == note.id);
    final next = <Note>[..._notes];
    if (index >= 0) {
      next[index] = note;
    } else {
      next.add(note);
    }
    _notes = next;
    notifyListeners();
  }

  Future<void> remove(Note note) async {
    await _store.deleteNote(note);
    _notes = _notes.where((item) => item.id != note.id).toList();
    notifyListeners();
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
}
