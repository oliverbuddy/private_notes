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

  testWidgets('提示条按内容收窄并悬浮', (WidgetTester tester) async {
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
    expect(snackBar.behavior, SnackBarBehavior.floating);
    // 纯提醒按内容收窄（最长 360），不再横贯整屏。
    expect(snackBar.width, lessThanOrEqualTo(360));
    expect(snackBar.width, greaterThanOrEqualTo(96));
    expect(snackBar.duration, const Duration(milliseconds: 1800));

    // 让 showSnack 的自动收起计时器跑完，避免测试结束时残留 Timer。
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('带「撤销」的提示条更宽但仍不超 360，且不溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showSnack(
                context,
                message: '已移到「回收站」',
                action: SnackBarAction(label: '撤销', onPressed: () {}),
              ),
              child: const Text('删除'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final SnackBar snackBar = tester.widget(find.byType(SnackBar));
    expect(snackBar.width, lessThanOrEqualTo(360));
    expect(snackBar.duration, const Duration(seconds: 4));

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('长提醒：到 360 就换行，不横向溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showSnack(
                context,
                message: '已从 12 条小记里移除这个标签，相关小记的内容不会受到影响',
              ),
              child: const Text('提示'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('提示'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 390 屏宽时上限是 390-32=358。
    expect(tester.widget<SnackBar>(find.byType(SnackBar)).width, 358);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('深色模式：提示条是深灰胶囊，不是整块反白', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
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

    // 实际画出来的底色来自主题（SnackBar 自身 backgroundColor 为 null）。
    final Material surface = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(surface.color, const Color(0xFF3A3D43));

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 400));
  });
}
