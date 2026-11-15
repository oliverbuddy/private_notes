import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/editor/lab/new_editor_page.dart';
import 'package:xiaoji/editor/lab/typora_table.dart';
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/theme/app_theme.dart';

/// Typora 式表格的交互回归：点击进格、Tab 切格、Enter 格内换行、
/// Cmd+Enter 插行。这些行为是「表格好不好用」的核心，必须有测试兜住。
Future<void> _pump(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<NoteRepository> _createRepository(WidgetTester tester) async {
  final Directory tempDir = Directory.systemTemp.createTempSync('xiaoji_table_');
  addTearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });
  late NoteRepository repository;
  await tester.runAsync(() async {
    final NoteStore store =
        await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
    repository = NoteRepository(store);
    await repository.load();
  });
  return repository;
}

const String _tableNote = '''
# 采购

| 名称 | 数量 |
| --- | --- |
| 苹果 | 3 |
''';

void main() {
  testWidgets('点击单元格就地编辑：Tab 切格、Enter 换行、Cmd+Enter 插行', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final NoteRepository repository = await _createRepository(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: NewEditorPage(
          repository: repository,
          note: Note(
            id: 'table1',
            created: DateTime(2026, 11, 15),
            updated: DateTime(2026, 11, 15),
            body: _tableNote,
          ),
        ),
      ),
    );
    await _pump(tester);

    expect(find.byType(TyporaTable), findsOneWidget);

    // 1) 点进「苹果」那一格：直接出现输入框，内容就是这一格。
    await tester.tap(find.text('苹果'));
    await _pump(tester);
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '苹果',
    );

    // 2) 改内容后 Tab：内容写回表格，编辑框落到下一格（数量 3）。
    await tester.enterText(find.byType(TextField), '香蕉');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await _pump(tester);
    expect(find.text('香蕉'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '3',
      reason: 'Tab 应该切到下一格并全选，而不是退出编辑',
    );

    // 3) Enter 不再跳到下一行：组件不劫持回车，留给输入框做格内换行。
    await tester.enterText(find.byType(TextField), '第一行');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _pump(tester);
    expect(
      find.byType(TextField),
      findsOneWidget,
      reason: 'Enter 不应提交并切格（Typora 里回车是格内换行）',
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '第一行',
    );

    // 4) Cmd+Enter：当前行下方插一行。
    final int before =
        tester.widget<Table>(find.byType(Table).first).children.length;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await _pump(tester);
    final int after =
        tester.widget<Table>(find.byType(Table).first).children.length;
    expect(after, before + 1, reason: 'Cmd+Enter 应在当前行下方插入一行');

    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
