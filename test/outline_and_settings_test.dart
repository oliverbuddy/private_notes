import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/editor/lab/new_editor_page.dart';
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/settings/settings_page.dart';
import 'package:xiaoji/theme/app_theme.dart';

Future<NoteRepository> _openRepository(Directory tempDir) async {
  final NoteStore store = await NoteStore.openAt(
    Directory(p.join(tempDir.path, 'Xiaoji')),
  );
  final NoteRepository repository = NoteRepository(store);
  await repository.load();
  return repository;
}

Future<void> _pumpFrames(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Note _note(String body) => Note(
  id: 'outline',
  created: DateTime(2026, 11, 1),
  updated: DateTime(2026, 11, 1),
  body: body,
);

void main() {
  testWidgets('标题 ≥ 2 时显示目录，点击可跳转且不抛异常', (WidgetTester tester) async {
    final Directory tempDir = Directory.systemTemp.createTempSync('xiaoji_out_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    late NoteRepository repository;
    await tester.runAsync(() async {
      repository = await _openRepository(tempDir);
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: NewEditorPage(
          repository: repository,
          note: _note('# 第一章\n\n正文 A\n\n## 小节\n\n正文 B\n'),
        ),
      ),
    );
    await _pumpFrames(tester);

    expect(find.byTooltip('目录'), findsOneWidget);
    await tester.tap(find.byTooltip('目录'));
    await _pumpFrames(tester);

    // 弹层里按层级列出两个标题。
    expect(find.byKey(const ValueKey<String>('outline-item-0')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('outline-item-1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('outline-item-1')));
    await _pumpFrames(tester, frames: 14);
    expect(tester.takeException(), isNull);
  });

  testWidgets('标题不足 2 个时不显示目录入口', (WidgetTester tester) async {
    final Directory tempDir = Directory.systemTemp.createTempSync('xiaoji_out1_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    late NoteRepository repository;
    await tester.runAsync(() async {
      repository = await _openRepository(tempDir);
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: NewEditorPage(
          repository: repository,
          note: _note('# 只有一章\n\n正文\n'),
        ),
      ),
    );
    await _pumpFrames(tester);

    expect(find.byTooltip('目录'), findsNothing);
  });

  testWidgets('设置页顶层已收敛：无标签管理 / 导入 Markdown / 自动锁定', (
    WidgetTester tester,
  ) async {
    final Directory tempDir = Directory.systemTemp.createTempSync('xiaoji_set_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    late NoteRepository repository;
    await tester.runAsync(() async {
      repository = await _openRepository(tempDir);
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: SettingsPage(repository: repository),
      ),
    );
    await _pumpFrames(tester);

    expect(find.text('应用锁'), findsOneWidget);
    expect(find.text('存储空间'), findsOneWidget);
    expect(find.text('备份与恢复'), findsOneWidget);
    // 三项低频/可迁移入口不再占顶层。
    expect(find.text('标签管理'), findsNothing);
    expect(find.text('导入 Markdown'), findsNothing);
    expect(find.text('自动锁定'), findsNothing);
  });
}
