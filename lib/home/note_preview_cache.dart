import 'dart:collection';

import '../editor/block.dart';
import '../models/note.dart';

/// 首页卡片预览的派生数据。
///
/// 列表每次通知/滚动都会重建卡片，而正文解析、首行摘要、图片/附件识别
/// 只和「正文内容」有关。这里按笔记 id 缓存一份，正文变了才重算。
class NotePreviewData {
  NotePreviewData._({
    required this.body,
    required this.segments,
    required this.images,
    required this.hasAttachment,
  });

  /// 生成这份数据时的正文，用来判断缓存是否还有效。
  final String body;

  /// 文字段 / 表格段序列（顺序与正文一致）。
  final List<NotePreviewSegment> segments;

  /// 正文里的图片块，供列表缩略图使用。
  final List<ImageBlock> images;

  /// 正文里是否有本地附件（紧凑列表的回形针标记）。
  final bool hasAttachment;

  String? _plainText;
  String? _firstLine;

  /// 搜索高亮用的纯文本摘要：只在搜索态首次访问时计算。
  String get plainText => _plainText ??= plainSummary(bodyWithoutTables(body));

  /// 紧凑列表的首行摘要素材。
  String get firstLine =>
      _firstLine ??= plainSummary(body).split('\n').first.trim();

  final Map<String, int> _lineCounts = <String, int>{};
  static const int _maxLineCounts = 12;

  int? lineCountOf(String key) => _lineCounts[key];

  void rememberLineCount(String key, int lines) {
    if (_lineCounts.length >= _maxLineCounts &&
        !_lineCounts.containsKey(key)) {
      _lineCounts.remove(_lineCounts.keys.first);
    }
    _lineCounts[key] = lines;
  }

  /// 锁定笔记 / 空内容共用的只读实例。
  factory NotePreviewData.empty() {
    return NotePreviewData._(
      body: '',
      segments: const <NotePreviewSegment>[],
      images: const <ImageBlock>[],
      hasAttachment: false,
    );
  }
}

/// 首页预览缓存：以笔记 id 为桶、正文变化为失效条件，LRU 上限 200 条。
class NotePreviewCache {
  NotePreviewCache({this.maxEntries = 200});

  final int maxEntries;

  final LinkedHashMap<String, NotePreviewData> _entries =
      LinkedHashMap<String, NotePreviewData>();

  static final NotePreviewData _empty = NotePreviewData.empty();

  NotePreviewData of(Note note) {
    if (note.locked) {
      return _empty;
    }
    final NotePreviewData? existing = _entries.remove(note.id);
    if (existing != null &&
        (identical(existing.body, note.body) || existing.body == note.body)) {
      // remove + 重新插入 = 命中后移到 LRU 队尾。
      _entries[note.id] = existing;
      return existing;
    }
    final NotePreviewData data = _build(note.body);
    _entries[note.id] = data;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return data;
  }

  NotePreviewData _build(String body) {
    final List<Block> blocks = parseBlocks(body);
    return NotePreviewData._(
      body: body,
      segments: previewSegmentsOf(body),
      images: blocks.whereType<ImageBlock>().toList(growable: false),
      hasAttachment: blocks.any((Block block) => block is FileBlock),
    );
  }

  void forget(String noteId) => _entries.remove(noteId);

  void clear() => _entries.clear();
}

/// 全局唯一实例：首页两种密度、紧凑/舒适卡片共用同一份缓存。
final NotePreviewCache notePreviewCache = NotePreviewCache();
