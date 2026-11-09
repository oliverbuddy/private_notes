import 'dart:math';

import '../util/date_format.dart';

/// 一条小记。
///
/// 刻意「无标题」：标题会让用户在记录前先做一次归类，
/// 而随手记的价值恰恰在于不用想。首行就是正文的一部分。
class Note {
  const Note({
    required this.id,
    required this.created,
    required this.updated,
    this.tags = const <String>[],
    this.pinned = false,
    this.locked = false,
    this.body = '',
  });

  /// 锁定正文在磁盘上的信封前缀。
  ///
  /// 锁定笔记的 frontmatter 保持明文（id/时间/标签），正文整体替换成
  /// `XIAOJI-LOCK-1:<base64(nonce|ciphertext)>`；读取时看到这个前缀
  /// 就知道正文是密文，不能当普通 markdown 渲染。
  static const String lockEnvelopePrefix = 'XIAOJI-LOCK-1:';

  /// `20261031-0912-a1b2`：创建时间 + 4 位随机 hex。
  final String id;
  final DateTime created;
  final DateTime updated;
  final List<String> tags;
  final bool pinned;

  /// 正文是否加密（单篇锁定）。
  final bool locked;

  /// 原始 markdown 正文（不含 frontmatter）。
  final String body;

  Note copyWith({
    String? id,
    DateTime? created,
    DateTime? updated,
    List<String>? tags,
    bool? pinned,
    bool? locked,
    String? body,
  }) {
    return Note(
      id: id ?? this.id,
      created: created ?? this.created,
      updated: updated ?? this.updated,
      tags: tags ?? this.tags,
      pinned: pinned ?? this.pinned,
      locked: locked ?? this.locked,
      body: body ?? this.body,
    );
  }

  /// 生成新笔记 id。时间戳前缀让文件名天然按时间排序。
  static String generateId(DateTime now) {
    final random = Random();
    final hex = random.nextInt(0xFFFF).toRadixString(16).padLeft(4, '0');
    return '${formatIdStamp(now)}-$hex';
  }

  /// 序列化成磁盘上的 .md 内容。
  String encode() {
    final buffer = StringBuffer()
      ..write('---\n')
      ..write('id: $id\n')
      ..write('created: ${formatIsoLocal(created)}\n')
      ..write('updated: ${formatIsoLocal(updated)}\n')
      ..write('tags: ${tags.join(', ')}\n')
      ..write(pinned ? 'pinned: true\n' : 'pinned: false\n')
      // 只在锁定笔记上写锁定字段：普通笔记的文件保持原样，不制造
      // 无意义的 diff（用户可能在「文件」App 里同步/比对）。
      ..write(locked ? 'locked: true\n' : '')
      ..write('---\n')
      ..write('\n')
      ..write(body);
    return buffer.toString();
  }

  /// 解析磁盘内容。无法解析时返回 null —— 调用方负责跳过这条坏文件，
  /// 绝不能让一条笔记把整个列表拖挂。
  ///
  /// [fallbackId] 一般传文件名，因为 frontmatter 被用户手改后可能缺 id。
  static Note? decode(String raw, {String? fallbackId}) {
    // 某些编辑器保存时会带 BOM，先剥掉再判断开头。
    var text = raw;
    if (text.startsWith('\uFEFF')) {
      text = text.substring(1);
    }
    if (!text.startsWith('---')) {
      return null;
    }
    final firstBreak = text.indexOf('\n');
    if (firstBreak < 0) {
      return null;
    }
    final closing = text.indexOf('\n---', firstBreak);
    if (closing < 0) {
      return null;
    }

    final header = text.substring(firstBreak + 1, closing);
    final bodyStart = closing + 4;
    var body = bodyStart <= text.length ? text.substring(bodyStart) : '';

    // 闭合 `---` 后面固定跟着两个换行：一个是该行的行尾，
    // 一个是我们自己写的、隔开 frontmatter 与正文的空行。
    // 两个都要吃掉，往返才不会在正文前面多出一个空行。
    for (var i = 0; i < 2; i++) {
      if (body.startsWith('\n')) {
        body = body.substring(1);
      } else {
        break;
      }
    }

    final fields = <String, String>{};
    for (final line in header.split('\n')) {
      final separator = line.indexOf(':');
      if (separator <= 0) {
        continue;
      }
      fields[line.substring(0, separator).trim()] =
          line.substring(separator + 1).trim();
    }

    final headerId = fields['id']?.trim();
    final id = (headerId != null && headerId.isNotEmpty) ? headerId : fallbackId;
    if (id == null || id.isEmpty) {
      return null;
    }

    final created = parseIsoLocal(fields['created'] ?? '') ??
        _parseFromId(id) ??
        DateTime.now();
    final updated = parseIsoLocal(fields['updated'] ?? '') ?? created;

    return Note(
      id: id,
      created: created,
      updated: updated.isBefore(created) ? created : updated,
      tags: parseTags(fields['tags'] ?? ''),
      pinned: (fields['pinned'] ?? 'false').toLowerCase() == 'true',
      locked: (fields['locked'] ?? 'false').toLowerCase() == 'true',
      body: body,
    );
  }

  /// 标签规范化：所有入口（编辑、重命名、合并、读盘）共用同一套规则，
  /// 避免「#工作」这类写法在不同页面被解释成不同东西。
  ///
  /// - 去掉首尾空白与换行；
  /// - 去掉前导 `#`（显示时才加回 `#`）；
  /// - 含分隔符（英文/中文逗号）或为空时返回 null，交给调用方拆分或报错。
  static String? normalizeTag(String raw) {
    var tag = raw.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    tag = tag.replaceFirst(RegExp(r'^#+'), '').trim();
    if (tag.isEmpty || tag.contains(',') || tag.contains('，')) {
      return null;
    }
    return tag;
  }

  /// 标签解析：英文逗号为主，同时兼容中文逗号（用户手写 frontmatter 时很常见）。
  ///
  /// 每一项都过一遍 [normalizeTag]，旧数据里带 `#` 的标签会在读盘时自动修正；
  /// 清洗后重复的标签只保留第一次出现的写法。
  static List<String> parseTags(String raw) {
    final result = <String>[];
    for (final piece in raw.split(RegExp(r'[,，]'))) {
      final tag = normalizeTag(piece);
      if (tag != null && !result.contains(tag)) {
        result.add(tag);
      }
    }
    return result;
  }

  /// 从 id 里的 `yyyyMMdd-HHmm` 反推创建时间，作为 frontmatter 缺失时的兜底。
  ///
  /// `DateTime(...)` 对越界分量只会**静默归一化**（13 月 → 次年 1 月、2 月 31 日
  /// → 3 月 3 日），不会抛 `ArgumentError`。所以必须自己校验范围，
  /// 否则一个被手改坏的 id 会变成「看起来完全合法」的错误时间，
  /// 笔记就悄悄排到列表的错误位置去了。
  static DateTime? _parseFromId(String id) {
    final match = RegExp(r'^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})').firstMatch(id);
    if (match == null) {
      return null;
    }
    final year = int.tryParse(match.group(1)!);
    final month = int.tryParse(match.group(2)!);
    final day = int.tryParse(match.group(3)!);
    final hour = int.tryParse(match.group(4)!);
    final minute = int.tryParse(match.group(5)!);
    if (year == null ||
        month == null ||
        day == null ||
        hour == null ||
        minute == null) {
      return null;
    }
    if (month < 1 || month > 12) {
      return null;
    }
    // 用当月真实天数校验：`20260231` 不该被静默归一化成 3 月 3 日。
    if (day < 1 || day > DateTime(year, month + 1, 0).day) {
      return null;
    }
    if (hour < 0 || hour > 23) {
      return null;
    }
    if (minute < 0 || minute > 59) {
      return null;
    }
    return DateTime(year, month, day, hour, minute);
  }

  @override
  String toString() => 'Note($id, pinned=$pinned, tags=$tags)';
}
