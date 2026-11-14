/// Markdown 快捷输入的兜底识别。
///
/// 内核已处理 ASCII 的 `# ` / `- ` / `1. ` / `> `；这里补上桌面端常见的
/// 两类差异，避免「同一段输入在手机上生效、PC 上不生效」：
///  - 中文输入法打出的全角空格（`\u3000`）与全角记号（`＋` / `＞` / `．`）；
///  - 待办前缀 `[] ` / `[ ] ` / `[x] `，内核没有对应的自动转换反应。
///
/// 纯函数，便于单测；只负责「识别前缀」，真正的文档改写留在编辑页。
enum MarkdownShortcut { h1, h2, h3, bullet, ordered, quote, todo }

class MarkdownShortcutMatch {
  const MarkdownShortcutMatch(this.shortcut, this.length);

  final MarkdownShortcut shortcut;

  /// 需要从正文里删掉的前缀长度（含结尾空格），按 UTF-16 下标计。
  final int length;
}

final RegExp _prefixPattern = RegExp(
  r'^(#{1,3}|[-*+＋]|1[.．]|>|＞|\[\s?[xX]?\s?\]|［\s?[xX]?\s?］)[ \u3000]$',
);

/// 匹配行首的 Markdown 快捷前缀；不匹配返回 null。
MarkdownShortcutMatch? matchMarkdownShortcut(String text) {
  final RegExpMatch? match = _prefixPattern.firstMatch(text);
  if (match == null) {
    return null;
  }
  final String marker = match.group(1)!;
  final MarkdownShortcut shortcut = switch (marker) {
    '#' => MarkdownShortcut.h1,
    '##' => MarkdownShortcut.h2,
    '###' => MarkdownShortcut.h3,
    '-' || '*' || '+' || '＋' => MarkdownShortcut.bullet,
    '1.' || '1．' => MarkdownShortcut.ordered,
    '>' || '＞' => MarkdownShortcut.quote,
    _ => MarkdownShortcut.todo,
  };
  return MarkdownShortcutMatch(shortcut, match.end);
}
