/// 时间与文件大小的格式化。
///
/// 刻意不用 intl：整个 app 只有中文 + 一种固定格式，多一个依赖不值得；
/// 而且 intl 需要额外初始化 locale，对「本地优先、无网络」的定位是负担。
library;

String _two(int value) => value.toString().padLeft(2, '0');

/// frontmatter 用的时间格式：本地时间、不带时区后缀。
///
/// 故意不带 `Z` 或 `+08:00`：这样用户换时区打开笔记时，
/// 文件内容不会被「改写」，符合「笔记就是纯文本」的直觉。
String formatIsoLocal(DateTime time) {
  final t = time.toLocal();
  return '${t.year}-${_two(t.month)}-${_two(t.day)}'
      'T${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
}

/// 严格的本地 ISO 时间串。
///
/// 刻意手写解析而不用 `DateTime.tryParse`：后者接受越界分量并**静默进位**
/// （`2026-13-05` → `2027-01-05`、`02-31` → `03-03`、`25:00` → 次日 01:00），
/// 于是 `Note.decode` 里 `parseIsoLocal(...) ?? 备用值` 的兜底永远执行不到，
/// 一条被手改坏的 frontmatter 会变成「看起来完全合法」的错误时间。
///
/// 兼容三种老格式：`T` 分隔、空格分隔、省略秒。
final RegExp _isoLocalPattern = RegExp(
  r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:[T ](\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?$',
);

/// 解析 [formatIsoLocal] 产出的字符串；也容忍带空格分隔符的老格式。
///
/// 无法解析或分量越界时返回 null，交给调用方回落备用值。
DateTime? parseIsoLocal(String raw) {
  final match = _isoLocalPattern.firstMatch(raw.trim());
  if (match == null) {
    return null;
  }

  int part(int index) => int.tryParse(match.group(index) ?? '') ?? 0;

  final year = part(1);
  final month = part(2);
  final day = part(3);
  final hour = match.group(4) == null ? 0 : part(4);
  final minute = match.group(5) == null ? 0 : part(5);
  final second = match.group(6) == null ? 0 : part(6);

  if (month < 1 || month > 12) {
    return null;
  }
  // `DateTime(year, month + 1, 0).day` 取当月真实天数，
  // 顺手挡掉「月份合法但当日在当月不存在」的 2026-02-31。
  if (day < 1 || day > DateTime(year, month + 1, 0).day) {
    return null;
  }
  if (hour > 23 || minute > 59 || second > 59) {
    return null;
  }

  return DateTime(year, month, day, hour, minute, second);
}

/// 笔记 id 里的时间戳部分：`20261031-0912`。
String formatIdStamp(DateTime time) {
  final t = time.toLocal();
  return '${t.year}${_two(t.month)}${_two(t.day)}'
      '-${_two(t.hour)}${_two(t.minute)}';
}

/// 导出目录名用的时间戳：`20261031-0912`。
String formatExportStamp(DateTime time) => formatIdStamp(time);

/// 日期是否是同一天（只比较年月日）。
bool isSameDay(DateTime a, DateTime b) {
  final x = a.toLocal();
  final y = b.toLocal();
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

/// 列表行用的时间：今天显示 `09:12`，昨天 `昨天 22:00`，今年 `10月31日`。
String formatListTime(DateTime time, {DateTime? now}) {
  final t = time.toLocal();
  final reference = (now ?? DateTime.now()).toLocal();
  if (isSameDay(t, reference)) {
    return '${_two(t.hour)}:${_two(t.minute)}';
  }
  final yesterday = reference.subtract(const Duration(days: 1));
  if (isSameDay(t, yesterday)) {
    // 只写「昨天」分不清是昨晚 11 点还是今天凌晨 1 点写的，带上时刻。
    return '昨天 ${_two(t.hour)}:${_two(t.minute)}';
  }
  if (t.year == reference.year) {
    return '${t.month}月${t.day}日';
  }
  return '${t.year}年${t.month}月${t.day}日';
}

/// 编辑页顶部的时间：带具体时刻。
String formatEditorTime(DateTime time, {DateTime? now}) {
  final t = time.toLocal();
  final reference = (now ?? DateTime.now()).toLocal();
  final clock = '${_two(t.hour)}:${_two(t.minute)}';
  if (isSameDay(t, reference)) {
    return '今天 $clock';
  }
  final yesterday = reference.subtract(const Duration(days: 1));
  if (isSameDay(t, yesterday)) {
    return '昨天 $clock';
  }
  if (t.year == reference.year) {
    return '${t.month}月${t.day}日 $clock';
  }
  return '${t.year}年${t.month}月${t.day}日 $clock';
}

/// 文件大小：小于 1 KB 用 B，小于 1 MB 用 KB，其余用 MB。
String formatFileSize(int bytes) {
  if (bytes < 0) {
    return '0 B';
  }
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    final kb = bytes / 1024;
    return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  }
  final mb = bytes / (1024 * 1024);
  return '${mb.toStringAsFixed(1)} MB';
}
