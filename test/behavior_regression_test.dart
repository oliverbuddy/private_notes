import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/editor/block.dart';
import 'package:xiaoji/editor/widgets/image_block_view.dart';
import 'package:xiaoji/home/home_page.dart';
import 'package:xiaoji/home/note_tile_comfortable.dart';
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/settings/tags_page.dart';
import 'package:xiaoji/theme/app_theme.dart';

/// 核心行为回归：
/// - 有序列表插入/删除一行后自动重新编号；
/// - 删除标签只摘标签，不动正文与修改时间。
Future<void> _pumpFrames(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 临时笔记目录（真实的 `Xiaoji` 根目录）。
Directory _tempRoot(String prefix) {
  final tempDir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });
  return Directory('${tempDir.path}/Xiaoji');
}

void main() {
  group('有序列表编号重排', () {
    test('删除一行后后面的编号顺延', () {
      final cursor = OrderedListNumberingCursor();
      final result = cursor.apply('1. 一\n3. 三\n4. 四');
      expect(result, isNotNull);
      expect(result!.text, '1. 一\n2. 三\n3. 四');
      expect(result.numberChanges.keys.toList(), <int>[1, 2]);
    });

    test('编号本来就连续时不产生任何改动', () {
      final cursor = OrderedListNumberingCursor();
      expect(cursor.apply('1. 一\n2. 二\n3. 三'), isNull);
    });

    test('空行会断开列表，不改远处的内容', () {
      final cursor = OrderedListNumberingCursor();
      expect(cursor.apply('1. 一\n\n5. 五'), isNull);
    });

    test('跨块继续：回车拆块后编号仍然连续', () {
      final cursor = OrderedListNumberingCursor();
      expect(cursor.apply('1. 一\n2. 二'), isNull);
      final result = cursor.apply('4. 四');
      expect(result, isNotNull);
      expect(result!.text, '3. 四');
    });

    test('普通段落断开列表，下一组重新起编号', () {
      final cursor = OrderedListNumberingCursor();
      cursor.apply('1. 一');
      expect(cursor.apply('普通段落'), isNull);
      expect(cursor.apply('9. 九'), isNull);
    });
  });

  test('删除标签只摘标签，不动正文和修改时间', () async {
    final root = _tempRoot('xiaoji_tag_del_');
    final store = await NoteStore.openAt(root);
    final repository = NoteRepository(store);
    final DateTime updated = DateTime(2026, 11, 1, 8, 0);
    await repository.upsert(
      Note(
        id: 'a',
        created: updated,
        updated: updated,
        tags: const <String>['读书', '想法'],
        body: '第一条',
      ),
    );
    await repository.upsert(
      Note(
        id: 'b',
        created: updated,
        updated: updated,
        tags: const <String>['读书'],
        body: '第二条',
      ),
    );
    repository.setActiveTag('读书');

    final removed = await repository.deleteTag('读书');

    expect(removed, 2);
    expect(repository.tags, <String>['想法']);
    expect(repository.activeTag, isNull, reason: '删掉的标签不能还挂在筛选上');
    expect(repository.notes.map((Note note) => note.body).toList(), <String>[
      '第一条',
      '第二条',
    ]);
    expect(
      repository.notes.every((Note note) => note.updated == updated),
      isTrue,
      reason: '整理标签不该把笔记顶到列表最前面',
    );
  });

  testWidgets('主页标签弹层只做筛选，不再提供删除入口', (WidgetTester tester) async {
    final root = _tempRoot('xiaoji_tag_ui_');
    late NoteRepository repository;
    await tester.runAsync(() async {
      repository = NoteRepository(await NoteStore.openAt(root));
      await repository.upsert(
        Note(
          id: 'tagged',
          created: DateTime(2026, 11, 1, 8, 0),
          updated: DateTime(2026, 11, 1, 8, 0),
          tags: const <String>['读书'],
          body: '带标签的一条',
        ),
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: HomePage(repository: repository),
      ),
    );
    await _pumpFrames(tester, frames: 8);

    // 打开标签筛选弹层，点标签即筛选并收起。
    await tester.tap(find.byIcon(Icons.sell_outlined));
    await _pumpFrames(tester, frames: 8);
    // 列表卡片上也有一个 #读书 chip，弹层里的那个在树里更靠后。
    expect(find.text('#读书'), findsWidgets);

    await tester.tap(find.text('#读书').last);
    await _pumpFrames(tester, frames: 8);

    expect(repository.activeTag, '读书');
    expect(find.text('删除标签 #读书？'), findsNothing);
    expect(repository.tags, <String>['读书']);
  });

  testWidgets('超长粘贴文本的摘要按卡片总行数封顶', (WidgetTester tester) async {
    final String longLine =
        '这是一段从别处复制过来的很长正文，用来测试摘要总行数上限。' * 3;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          // 列表里高度是无界的，这里用滚动容器还原同样的约束。
          body: SingleChildScrollView(
            child: NoteTileComfortable(
              note: Note(
                id: 'long',
                created: DateTime(2026, 11, 1, 8, 0),
                updated: DateTime(2026, 11, 1, 8, 0),
                body: List<String>.filled(5, longLine).join('\n'),
              ),
              thumbnailPaths: const <String>[],
              onTap: () {},
              onLongPress: () {},
            ),
          ),
        ),
      ),
    );
    await _pumpFrames(tester, frames: 4);

    // 5 行摘要 ≈ 5 × 23px ≈ 116px；标题/时间/内边距合计约 100px。
    // 旧实现每块各自 maxLines，长行折行后能到 20 行左右（> 500px）。
    final double tileHeight =
        tester.getSize(find.byType(NoteTileComfortable)).height;
    expect(tileHeight, lessThan(300));
  });

  testWidgets('标签管理页点「…」可以删除标签', (WidgetTester tester) async {
    final root = _tempRoot('xiaoji_tag_manage_');
    late NoteRepository repository;
    await tester.runAsync(() async {
      repository = NoteRepository(await NoteStore.openAt(root));
      await repository.upsert(
        Note(
          id: 'tagged',
          created: DateTime(2026, 11, 1, 8, 0),
          updated: DateTime(2026, 11, 1, 8, 0),
          tags: const <String>['读书'],
          body: '带标签的一条',
        ),
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: TagsPage(repository: repository),
      ),
    );
    await _pumpFrames(tester, frames: 8);
    expect(find.text('#读书'), findsOneWidget);

    // 行尾「…」→ 删除标签 → 二次确认。
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await _pumpFrames(tester, frames: 8);
    await tester.tap(find.text('删除标签'));
    await _pumpFrames(tester, frames: 8);
    expect(find.text('删除标签「读书」？'), findsOneWidget);

    await tester.tap(find.text('删除标签'));
    // 删除要真实落盘（saveNote 是真实文件 I/O）：交替「让出真实时间」与
    // 「pump 冲刷微任务」，await 链才能一步步推进。
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      await _pumpFrames(tester, frames: 2);
    }

    expect(repository.tags, isEmpty);

    // 删除成功会出 4 秒提示条：把计时器走完，避免测试结束仍挂着 Timer。
    await tester.pump(const Duration(seconds: 5));
    await _pumpFrames(tester, frames: 4);
  });

  testWidgets('图片查看器的视口是整屏，双击放大后仍铺满屏幕', (WidgetTester tester) async {
    final tempDir = Directory.systemTemp.createTempSync('xiaoji_viewer_');
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });
    // 1x1 透明 PNG：测试只关心布局，不关心像素内容。
    final File image = File('${tempDir.path}/a.png')
      ..writeAsBytesSync(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
        'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      ));
    final ValueNotifier<Offset> dragOffset = ValueNotifier<Offset>(Offset.zero);
    addTearDown(dragOffset.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ImageViewerPage(
          absolutePath: image.path,
          dragOffset: dragOffset,
        ),
      ),
    );
    await _pumpFrames(tester, frames: 6);

    // 视口必须是整屏：之前 InteractiveViewer 只有图片那么大，
    // 双击放大后图片会被这块小视口裁掉一部分（用户实测）。
    final Size view = tester.view.physicalSize / tester.view.devicePixelRatio;
    final Size viewerSize = tester.getSize(find.byType(InteractiveViewer));
    expect(viewerSize.width, closeTo(view.width, 0.5));
    expect(viewerSize.height, closeTo(view.height, 0.5));

    // 双击中心放大到 2.5 倍。
    final Offset center = tester.getCenter(find.byType(InteractiveViewer));
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(center);
    await _pumpFrames(tester, frames: 8);

    final TransformationController transform = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    expect(transform.value.getMaxScaleOnAxis(), closeTo(2.5, 0.05));
  });

  // 用户反馈：图片查看没放大时只能上下拖。微信是「图随手走」——任意方向
  // 拖动图片都跟手，并按离原点的距离等比缩小。
  testWidgets('图片查看器 1x 时任意方向拖动都跟手', (WidgetTester tester) async {
    final tempDir = Directory.systemTemp.createTempSync('xiaoji_viewer_');
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });
    final File image = File('${tempDir.path}/a.png')
      ..writeAsBytesSync(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
        'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      ));
    final ValueNotifier<Offset> dragOffset = ValueNotifier<Offset>(Offset.zero);
    addTearDown(dragOffset.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ImageViewerPage(
          absolutePath: image.path,
          dragOffset: dragOffset,
        ),
      ),
    );
    await _pumpFrames(tester, frames: 6);

    // 竖直拖动：跟手（小于关闭阈值，松手回弹）。
    final Offset center = tester.getCenter(find.byType(InteractiveViewer));
    final TestGesture vertical = await tester.startGesture(center);
    await vertical.moveBy(const Offset(0, 90));
    await tester.pump();
    expect(dragOffset.value.dy, closeTo(90, 2));
    await vertical.up();
    await _pumpFrames(tester, frames: 8); // 回弹

    // 横向拖动：同样跟手，且不触发关闭。
    final TestGesture horizontal = await tester.startGesture(center);
    await horizontal.moveBy(const Offset(90, 0));
    await tester.pump();
    expect(dragOffset.value.dx, closeTo(90, 2));
    expect(dragOffset.value.dy, closeTo(0, 2));
    await horizontal.up();
    // 双击识别器的计时器要走完，否则测试收尾会报 pending timer。
    await tester.pump(const Duration(milliseconds: 400));
  });

  // 用户反馈：单击开关顶栏。微信里单击是隐藏/显示顶栏。
  testWidgets('图片查看器单击切换顶栏', (WidgetTester tester) async {
    final tempDir = Directory.systemTemp.createTempSync('xiaoji_viewer_');
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });
    final File image = File('${tempDir.path}/a.png')
      ..writeAsBytesSync(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
        'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      ));
    final ValueNotifier<Offset> dragOffset = ValueNotifier<Offset>(Offset.zero);
    addTearDown(dragOffset.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ImageViewerPage(
          absolutePath: image.path,
          dragOffset: dragOffset,
        ),
      ),
    );
    await _pumpFrames(tester, frames: 6);

    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );

    await tester.tapAt(tester.getCenter(find.byType(InteractiveViewer)));
    // 单击要等双击计时窗口结束才成立。
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
  });
}
