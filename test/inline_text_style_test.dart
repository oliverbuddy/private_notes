import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';
import 'package:xiaoji/editor/lab/new_editor_page.dart';
import 'package:xiaoji/editor/lab/xiaoji_markdown.dart';
import 'package:xiaoji/theme/app_theme.dart';

/// 编辑态行内样式的回归测试。
///
/// 背景：内核的 `defaultStyleBuilder` 不处理 `codeAttribution`，行内码在
/// 编辑器里曾经「加了属性但毫无视觉变化」；高亮则因为样式表合并机制
/// 静默丢弃了自定义 inlineTextStyler。这里锁住六种行内属性的最终样式。
void main() {
  const TextStyle base = TextStyle(fontSize: 16);
  const Color textColor = Color(0xFF222222);
  const Color accentColor = Color(0xFF0A6CFF);
  const Color mutedColor = Color(0xFF8A8A8A);
  const Color codeBackground = Color(0xFFF1F3F5);
  const Color highlightBackground = Color(0xFFE8F0FF);

  TextStyle styleFor(Set<Attribution> attributions) {
    return xiaojiInlineTextStyler(
      attributions,
      base,
      textColor: textColor,
      accentColor: accentColor,
      mutedColor: mutedColor,
      codeBackground: codeBackground,
      highlightBackground: highlightBackground,
    );
  }

  test('加粗对齐阅读态的 600，斜体沿用内核默认', () {
    expect(styleFor(<Attribution>{boldAttribution}).fontWeight,
        AppWeight.semibold);
    expect(styleFor(<Attribution>{italicsAttribution}).fontStyle,
        FontStyle.italic);
  });

  test('删除线与列表摘要一致：划线 + 三级文字色', () {
    final TextStyle style = styleFor(<Attribution>{strikethroughAttribution});
    expect(style.decoration, TextDecoration.lineThrough);
    expect(style.color, mutedColor);
  });

  test('行内码补上等宽 + 浅底 + 微缩', () {
    final TextStyle style = styleFor(<Attribution>{codeAttribution});
    expect(style.fontFamily, 'monospace');
    expect(style.backgroundColor, codeBackground);
    expect(style.fontSize, closeTo(16 * 0.9, 0.001));
  });

  test('高亮补上底色', () {
    expect(styleFor(<Attribution>{highlightAttribution}).backgroundColor,
        highlightBackground);
  });

  test('链接用应用主色 + 下划线（不是内核默认的 lightBlue）', () {
    final TextStyle style =
        styleFor(<Attribution>{const LinkAttribution('https://x.test')});
    expect(style.decoration, TextDecoration.underline);
    expect(style.color, accentColor);
    expect(style.decorationColor, accentColor);
  });
}
