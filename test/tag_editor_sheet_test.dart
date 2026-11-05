import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/tag_editor_sheet.dart';
import 'package:xiaoji/theme/app_theme.dart';

/// 标签弹层的交互契约：
///  - 已选标签只在候选区呈现，**不回填输入框**；
///  - 输入框只用于新增，提交后立刻清空；
///  - 候选区点选/取消直接改变已选集合。
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

    // 候选区同时展示已选和未选标签。
    expect(find.text('#旅行'), findsOneWidget);
    expect(find.text('#想法'), findsOneWidget);

    // 输入新标签 → 添加 → 输入框清空、候选区出现新标签。
    await tester.enterText(find.byType(TextField), '新的');
    await tester.pump();
    await tester.tap(find.text('添加'));
    await tester.pump();
    expect(find.text('#新的'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text ?? '',
      isEmpty,
    );

    // 候选区点选：点「想法」把它加入已选（选中态由背景色区分，不重复渲染文字）。
    await tester.tap(find.text('#想法'));
    await tester.pump();

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(result, contains('旅行'));
    expect(result, contains('新的'));
    expect(result, contains('想法'));
  });
}
