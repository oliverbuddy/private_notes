import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/markdown_toolbar.dart';
import 'package:xiaoji/theme/app_theme.dart';

/// 详情页底部工具栏 / Aa 面板的跨机型布局回归。
///
/// 用户反馈「有的机型工具栏不好看」，实测两个问题：
///  - 320dp 窄屏上，三个内容按钮 + 撤销/还原 + 收键盘按 48dp 热区会
///    横向溢出 13dp；
///  - 320dp + 系统大字号时，结构组「分隔线 / 减少缩进」的标签被省略号截断。
/// 现在窄屏收一档热区（44dp）、标签按卡片宽度做 scaleDown，本文件把
/// 320 / 360 / 412dp 与 1.0 / 1.3 倍字号都覆盖，任何溢出或截断都会失败。
Future<void> _pump(
  WidgetTester tester,
  Widget child,
  double width,
  double scale,
) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Align(alignment: Alignment.bottomCenter, child: child),
      ),
    ),
  );
  await tester.pump();
}

Widget _toolbar() {
  return MarkdownToolbar(
    onCommand: (_) {},
    onAttachAction: (_) {},
    onHideKeyboard: () {},
    panel: MarkdownToolbarPanel.none,
    onPanelToggle: (_) {},
    onEditTags: () {},
    onUndo: () {},
    onRedo: () {},
    canUndo: true,
    canRedo: true,
  );
}

void main() {
  for (final double width in <double>[320, 360, 412]) {
    for (final double scale in <double>[1.0, 1.3]) {
      testWidgets(
        '工具栏 ${width.toInt()}dp x $scale 不溢出',
        (WidgetTester tester) async {
          await _pump(tester, _toolbar(), width, scale);
        },
      );
    }
  }

  for (final double width in <double>[320, 360]) {
    testWidgets('Aa 面板 ${width.toInt()}dp + 1.3 字号无溢出、标签完整',
        (WidgetTester tester) async {
      await _pump(
        tester,
        MarkdownTextStylePanel(
          active: const <MarkdownCommand>{},
          onPick: (_) {},
        ),
        width,
        1.3,
      );
      // 四组里最长的几个标签：窄屏 + 大字号时以前会被省略号截断。
      for (final String label in <String>[
        '待办',
        '无序',
        '有序',
        '引用',
        '加粗',
        '删除线',
        '行内码',
        '高亮',
        '链接',
        '分隔线',
        '代码块',
        '缩进',
        '减少缩进',
      ]) {
        final RenderParagraph paragraph =
            tester.renderObject<RenderParagraph>(find.text(label));
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: '$label 在 ${width.toInt()}dp + 1.3 下被截断',
        );
      }
    });
  }

  testWidgets('插入面板 320dp + 1.3 字号不溢出', (WidgetTester tester) async {
    await _pump(
      tester,
      MarkdownAttachPanel(onPick: (_) {}),
      320,
      1.3,
    );
  });
}
