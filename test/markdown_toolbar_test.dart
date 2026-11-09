import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/markdown_toolbar.dart';
import 'package:xiaoji/theme/app_theme.dart';

/// Aa 面板的布局回归：
///  - 「文字」行 6 项若排成一行，每列只有约 43dp，「删除线 / 行内码」
///    会被 ellipsis 截断（用户反馈显示不全）；
///  - 改为 3 列 × 2 行后，在 320 / 360 / 411 三种常见宽度下标签必须
///    完整显示，不允许出现省略号。
void main() {
  Future<void> pumpPanel(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: MarkdownTextStylePanel(
              active: const <MarkdownCommand>{},
              onPick: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const List<String> inlineLabels = <String>[
    '加粗',
    '斜体',
    '删除线',
    '行内码',
    '高亮',
    '链接',
  ];

  for (final double width in <double>[320, 360, 411]) {
    testWidgets('文字行标签在 ${width.toInt()}dp 下完整显示', (WidgetTester tester) async {
      await pumpPanel(tester, width);
      for (final String label in inlineLabels) {
        final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
          find.text(label),
        );
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: '$label 在 ${width.toInt()}dp 下被省略号截断',
        );
      }
    });
  }

  testWidgets('面板高度与常量一致，六种行内样式都在', (WidgetTester tester) async {
    await pumpPanel(tester, 360);
    expect(
      tester.getSize(find.byType(MarkdownTextStylePanel)).height,
      MarkdownTextStylePanel.height,
    );
    for (final String label in inlineLabels) {
      expect(find.text(label), findsOneWidget);
    }
    // 行内码与代码块必须是两个不同图标（此前同为 code 图标，容易误点）。
    final Icon inlineCode = tester.widget<Icon>(
      find.byIcon(Icons.terminal_rounded),
    );
    expect(inlineCode.icon, Icons.terminal_rounded);
    expect(find.byIcon(Icons.code_rounded), findsOneWidget);
  });

  testWidgets('点行内样式只回调命令，不弹任何提示', (WidgetTester tester) async {
    MarkdownCommand? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: MarkdownTextStylePanel(
              active: const <MarkdownCommand>{},
              onPick: (MarkdownCommand command) => picked = command,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('加粗'));
    await tester.pump();

    expect(picked, MarkdownCommand.bold);
    expect(
      find.byType(SnackBar),
      findsNothing,
      reason: '面板只回调命令；折叠光标的输入态由按钮点亮反馈，不弹提示',
    );
    expect(find.text('加粗'), findsOneWidget, reason: '面板保持展开，可连续点样式');
  });
}
