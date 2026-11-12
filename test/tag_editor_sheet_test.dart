import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/tag_editor_sheet.dart';
import 'package:xiaoji/theme/app_theme.dart';

/// 标签弹层的交互契约：
///  - 已选标签单独一栏（彩色胶囊），**不回填输入框**；
///  - 输入框只用于新增，提交后立刻清空；
///  - 「全部标签」里只放未选项，点选后移到已选栏，取消后回到未选栏。
void main() {
  testWidgets('已选标签不回填输入框，输入框只负责新增', (WidgetTester tester) async {
    String? result;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showTagEditorSheet(
                    context: context,
                    initialText: '旅行',
                    candidates: const <String>['旅行', '想法'],
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    // 已选标签（旅行）不回填输入框：输入框必须是空的。
    final TextField field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text ?? '', isEmpty);

    // 已选栏 + 未选栏各展示一次，不会重复。
    expect(find.text('#旅行'), findsOneWidget);
    expect(find.text('#想法'), findsOneWidget);
    expect(find.text('已选 1'), findsOneWidget);

    // 输入新标签 → 添加 → 输入框清空、已选栏出现新标签。
    await tester.enterText(find.byType(TextField), '新的');
    await tester.pump();
    await tester.tap(find.byTooltip('添加标签'));
    await tester.pump();
    expect(find.text('#新的'), findsOneWidget);
    expect(find.text('已选 2'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text ?? '',
      isEmpty,
    );

    // 点「全部标签」里的「想法」：加入已选，从下方列表消失。
    await tester.tap(find.text('#想法'));
    await tester.pump();
    expect(find.text('#想法'), findsOneWidget);
    expect(find.text('已选 3'), findsOneWidget);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(result, contains('旅行'));
    expect(result, contains('新的'));
    expect(result, contains('想法'));
  });

  testWidgets('小屏 + 键盘弹出 + 标签很多时弹层不溢出', (WidgetTester tester) async {
    // 360×640 的小屏，模拟 300dp 高的键盘：内容区必须能滚动，
    // 底部按钮不能被挤出屏幕，也不能出现 RenderFlex overflow。
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3;
    tester.view.viewInsets = const FakeViewPadding(bottom: 900);
    addTearDown(tester.view.reset);

    final List<String> tags = <String>[
      '旅行',
      for (int index = 0; index < 30; index += 1) '标签$index',
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showTagEditorSheet(
                  context: context,
                  initialText: '旅行',
                  candidates: tags,
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 底部按钮仍在屏幕内，可以正常点。
    expect(find.text('完成'), findsOneWidget);
    expect(tester.getRect(find.text('完成')).bottom, lessThanOrEqualTo(640));
  });
}
