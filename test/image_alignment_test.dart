import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/editor/lab/new_editor_page.dart';
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/theme/app_theme.dart';
import 'package:xiaoji/ui/adaptive_image.dart';

Future<void> _pumpFrames(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  late Directory tempDir;
  late NoteRepository repository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('xiaoji_image_align_');
    final NoteStore store =
        await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
    repository = NoteRepository(store);
    await repository.load();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets('详情页图片与正文左对齐，且位于两段文字之间', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: NewEditorPage(
          repository: repository,
          note: Note(
            id: 'img-align',
            created: DateTime(2026, 11, 1),
            updated: DateTime(2026, 11, 1),
            body: '第一段文字\n\n![](assets/img-align/missing.png)\n\n第二段文字',
          ),
        ),
      ),
    );
    await _pumpFrames(tester);

    final Rect text = tester.getRect(find.text('第一段文字', findRichText: true));
    final Rect frame = tester.getRect(find.byType(AdaptiveImageFrame));
    // ignore: avoid_print
    print('DBG text=$text frame=$frame');

    expect(frame.left, closeTo(text.left, 0.5));
    expect(frame.top, greaterThan(text.top));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });
}
