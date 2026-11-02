import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/markdown_controller.dart';
import 'package:xiaoji/theme/app_theme.dart';

/// 编辑态的标题行必须按放大后的字号渲染。
///
/// 这个文件以前只 print span、不写断言，等于没测：标题渲染坏掉也不会变红。
void main() {
  testWidgets('标题行的渲染字号是正文的 1.5 倍', (WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (BuildContext context) {
            captured = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    const double baseSize = 17;
    final controller = MarkdownEditingController(text: '# 标题');
    final TextSpan span = controller.buildTextSpan(
      context: captured,
      style: const TextStyle(fontSize: baseSize, height: 1.72),
      withComposing: false,
    );

    TextStyle? headingStyle;
    void visit(InlineSpan node) {
      if (node is! TextSpan) {
        return;
      }
      if (node.text == '标题') {
        headingStyle = node.style;
      }
      for (final InlineSpan child in node.children ?? const <InlineSpan>[]) {
        visit(child);
      }
    }

    visit(span);

    expect(headingStyle, isNotNull, reason: '标题正文应该单独成为一段 span');
    expect(headingStyle!.fontSize, closeTo(baseSize * 1.5, 0.01));
    expect(headingStyle!.fontWeight, AppWeight.semibold);
  });

  testWidgets('输入法组词期间标题样式仍然生效，只多一条下划线', (WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (BuildContext context) {
            captured = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    const double baseSize = 17;
    final controller = MarkdownEditingController(text: '# 标题');
    // 组词区间盖住「标题」两个字符。
    controller.value = const TextEditingValue(
      text: '# 标题',
      selection: TextSelection.collapsed(offset: 4),
      composing: TextRange(start: 2, end: 4),
    );

    final TextSpan span = controller.buildTextSpan(
      context: captured,
      style: const TextStyle(fontSize: baseSize, height: 1.72),
      withComposing: true,
    );

    TextStyle? composingStyle;
    void visit(InlineSpan node) {
      if (node is! TextSpan) {
        return;
      }
      if (node.text == '标题') {
        composingStyle = node.style;
      }
      for (final InlineSpan child in node.children ?? const <InlineSpan>[]) {
        visit(child);
      }
    }

    visit(span);

    expect(composingStyle, isNotNull);
    expect(
      composingStyle!.fontSize,
      closeTo(baseSize * 1.5, 0.01),
      reason: '组词时不能退回正文字号（否则整行会跳一下）',
    );
    expect(composingStyle!.decoration, TextDecoration.underline);
  });
}
