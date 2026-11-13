import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:super_editor/super_editor.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/editor/lab/new_editor_page.dart';
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/theme/app_theme.dart';

/// 长文性能基线：3000 字 + 20 张图片的笔记要能打开、滚动、继续输入。
///
/// 这是「回归护栏」而不是性能压测：只断言不抛异常、不超时，
/// 具体耗时打印到日志里，后续版本可以对照趋势。
const String _onePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8'
    'BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

Future<void> _pumpFrames(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

String _longBody() {
  final StringBuffer buffer = StringBuffer();
  for (var i = 0; i < 60; i++) {
    buffer.writeln(
      '第 $i 段：这是用于验证长文滚动与编辑性能的一段中文正文，'
      '长度接近真实会议记录，包含标点、数字 12345 和英文 flutter。',
    );
    if (i % 3 == 0) {
      // 每三段插一张图，共 20 张。
      buffer.writeln('![图 $i](assets/perf/${i ~/ 3 + 1}.png)');
      buffer.writeln();
    }
  }
  return buffer.toString();
}

void main() {
  testWidgets(
    '3000 字 + 20 图：打开、滚动、输入都不出异常',
    (WidgetTester tester) async {
      final Directory tempDir =
          Directory.systemTemp.createTempSync('xiaoji_perf_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      late NoteRepository repository;
      await tester.runAsync(() async {
        final NoteStore store =
            await NoteStore.openAt(Directory(p.join(tempDir.path, 'Xiaoji')));
        repository = NoteRepository(store);
        await repository.load();
        final Directory assets = store.assetDirectoryOf('perf');
        await assets.create(recursive: true);
        final List<int> bytes = base64Decode(_onePixelPng);
        for (var i = 1; i <= 20; i++) {
          await File(p.join(assets.path, '$i.png')).writeAsBytes(bytes);
        }
      });

      final Note note = Note(
        id: 'perf',
        created: DateTime(2026, 11, 12, 9),
        updated: DateTime(2026, 11, 12, 9),
        body: _longBody(),
      );

      final Stopwatch stopwatch = Stopwatch()..start();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: NewEditorPage(
            repository: repository,
            note: note,
            autoFocus: false,
          ),
        ),
      );
      await _pumpFrames(tester);
      stopwatch.stop();
      debugPrint('[perf] 首屏渲染 ${stopwatch.elapsedMilliseconds}ms');

      expect(tester.takeException(), isNull);

      // 来回滚动两屏，模拟用户翻长文。
      await tester.drag(
        find.byType(NewEditorPage),
        const Offset(0, -1200),
      );
      await _pumpFrames(tester, frames: 6);
      expect(tester.takeException(), isNull);

      await tester.drag(
        find.byType(NewEditorPage),
        const Offset(0, 900),
      );
      await _pumpFrames(tester, frames: 6);
      expect(tester.takeException(), isNull);

      // 长文中间继续输入，确认不会因为块太多而崩。
      await tester.tap(find.byType(SuperEditor).first);
      await tester.pump(const Duration(milliseconds: 120));
      tester.testTextInput.enterText('追加一段');
      await _pumpFrames(tester, frames: 4);
      expect(tester.takeException(), isNull);

      // 收尾：把页面拆掉，并把 super_editor 点击后启动的
      // 5 秒「自动隐藏选择手柄」计时器跑完，避免 pending timer 报错。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 6));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
