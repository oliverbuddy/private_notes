import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/home/home_page.dart';
import 'package:xiaoji/theme/app_theme.dart';
import 'package:xiaoji/ui/show_sheet.dart';
import 'package:xiaoji/ui/snack.dart';

/// 平板适配回归：内容版心 680/760 下，贴边元素必须跟着版心走。
///
/// 用户在平板上实测后反馈「大部分没问题，但贴边元素会错位」：
///  - 主页悬浮球原来固定在屏幕最右缘，正文却收窄居中；
///  - 历史版本/预览这类大面板原来铺满整屏，长文一行拉得过长；
///  - 提示条横贯整屏，和一列居中的内容不在一个视觉轴上。
Future<void> _pumpFrames(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<NoteRepository> _createRepository(WidgetTester tester) async {
  final Directory tempDir = Directory.systemTemp.createTempSync('xiaoji_pad_');
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

void main() {
  const Size padSize = Size(900, 1200);
  final double contentRight =
      (padSize.width + AppBreakpoints.contentMaxWidth(padSize.width)) / 2;

  testWidgets('平板：主页悬浮球跟随内容版心', (WidgetTester tester) async {
    tester.view.physicalSize = padSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final NoteRepository repository = await _createRepository(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: HomePage(repository: repository),
      ),
    );
    await _pumpFrames(tester);

    final Rect fab = tester.getRect(find.byTooltip('新建小记'));
    expect(fab.right, closeTo(contentRight - 16, 1));
  });

  testWidgets('平板：大面板收窄到 560 并居中', (WidgetTester tester) async {
    tester.view.physicalSize = padSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showXiaojiPanel<void>(
                context: context,
                builder: (_) => const SizedBox(
                  key: ValueKey<String>('pad-panel'),
                  width: double.infinity,
                  height: 200,
                ),
              ),
              child: const Text('打开面板'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开面板'));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(const ValueKey<String>('pad-panel'))).width,
      kXiaojiSheetMaxWidth,
    );
  });

  testWidgets('平板：提示条为 480 宽悬浮', (WidgetTester tester) async {
    tester.view.physicalSize = padSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showSnack(context, message: '已保存'),
              child: const Text('提示'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('提示'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final SnackBar snackBar = tester.widget(find.byType(SnackBar));
    expect(snackBar.width, 480);
    expect(snackBar.behavior, SnackBarBehavior.floating);

    // 让 showSnack 的自动收起计时器跑完，避免测试结束时残留 Timer。
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 400));
  });
}
