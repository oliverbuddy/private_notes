import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/editor/editor_page.dart';
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/theme/app_theme.dart';

Future<void> _pumpFrames(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  testWidgets('编辑标签保存后不崩溃', (WidgetTester tester) async {
    final tempDir = Directory.systemTemp.createTempSync('xiaoji_tag_');
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    late NoteRepository repository;
    await tester.runAsync(() async {
      final store = await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
      repository = NoteRepository(store);
      await repository.load();
      await repository.upsert(
        Note(
          id: 'tag-crash',
          created: DateTime(2026, 10, 31, 9, 12),
          updated: DateTime(2026, 10, 31, 9, 20),
          body: '第一段',
        ),
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: EditorPage(repository: repository, note: repository.notes.first),
      ),
    );
    await _pumpFrames(tester, frames: 10);

    // 进编辑态。
    await tester.tap(find.text('第一段').last);
    await _pumpFrames(tester, frames: 6);

    // 打开标签编辑弹层（左下角「＋ 标签」占位）。
    await tester.tap(find.text('标签'));
    await _pumpFrames(tester, frames: 8);

    await tester.enterText(find.byType(TextField).last, '旅行');
    await _pumpFrames(tester, frames: 2);

    await tester.tap(find.text('保存'));
    // 弹层退场动画 320ms。
    await _pumpFrames(tester, frames: 12);
    await _pumpFrames(tester, frames: 6);

    // fakeAsync 里真实落盘不会完成，断言界面状态：左下角常驻标签栏出现 chip。
    expect(find.text('#旅行'), findsOneWidget);
  });
}
