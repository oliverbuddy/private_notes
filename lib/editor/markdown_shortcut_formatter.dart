import 'package:flutter/services.dart';

/// 输入即转换：行首敲完记号再敲空格，归一化成渲染器认识的形式。
///
/// 语雀的 Markdown 快捷输入（`# ` / `- ` / `1. ` / `> ` / `[] `）我们本来就
/// 按 markdown 直接渲染，真正需要「转换」的只有等价写法：
/// `[]`、`[x]` 要补成待办，`*`、`+` 要统一成 `-`（否则同一篇里记号混用）。
///
/// 为什么放在 [TextInputFormatter] 而不是「监听文本变化后改写 controller」：
/// 输入法组词期间改写文本会被 IME 的下一次提交覆盖回去（真机上 `[] ` 只会
/// 变成 `- []`，中间的空格丢了）。formatter 是 IME 管线的标准改写点，
/// 顺带把 composing 清干净。
class MarkdownShortcutFormatter extends TextInputFormatter {
  const MarkdownShortcutFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final String text = newValue.text;
    final TextSelection selection = newValue.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      return newValue;
    }
    final int offset = selection.baseOffset;
    if (offset < 2 || offset > text.length || text[offset - 1] != ' ') {
      return newValue;
    }
    final int lineStart =
        offset - 1 <= 0 ? 0 : text.lastIndexOf('\n', offset - 2) + 1;
    final String typed = text.substring(lineStart, offset);
    final String? replacement = markerReplacementFor(typed);
    if (replacement == null) {
      return newValue;
    }
    return TextEditingValue(
      text: text.replaceRange(lineStart, offset, replacement),
      selection: TextSelection.collapsed(
        offset: lineStart + replacement.length,
      ),
      composing: TextRange.empty,
    );
  }

  /// 行首记号的等价写法 → 规范写法（含末尾那个空格）。
  ///
  /// 返回 null 表示不需要改写。`# `、`- `、`1. `、`> ` 本来就是规范写法，
  /// 渲染器直接认，不用动。
  static String? markerReplacementFor(String typed) {
    switch (typed) {
      case '* ':
      case '+ ':
        return '- ';
      case '[] ':
      case '[ ] ':
        return '- [ ] ';
      case '[x] ':
      case '[X] ':
        return '- [x] ';
      default:
        return null;
    }
  }
}
