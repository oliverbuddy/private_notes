import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/editor/editor_zoom.dart';
import 'package:xiaoji/editor/lab/caret_overlay.dart';
import 'package:xiaoji/editor/lab/new_editor_page.dart';
import 'package:xiaoji/home/home_page.dart';
import 'package:xiaoji/home/note_tile_comfortable.dart';
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/settings/backup_sheets.dart';
import 'package:xiaoji/theme/app_theme.dart';
import 'package:xiaoji/ui/show_sheet.dart';
import 'package:xiaoji/util/native_zip.dart';

/// 桌面（PC）与平板（Pad）的流程回归。
///
/// 本地没有 Xcode / Visual Studio，跑不了真机 GUI；这里覆盖的是
/// 「换成桌面平台后 Dart 侧走哪条路、会不会留垃圾、宽屏会不会溢出」——
/// 原生部分由 GitHub Actions 在对应系统上编译验证。
Future<void> _pumpFrames(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 按住 ⌘ 敲一个键（桌面缩放快捷键走 Meta；Windows 的 Ctrl 分支同一份表）。
Future<void> _pressWithMeta(
  WidgetTester tester,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
}

/// 面板测试的最小宿主页：一个按钮打开 [showXiaojiPanel]。
Future<void> _pumpPanelHost(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showXiaojiPanel<void>(
                context: context,
                builder: (BuildContext panelContext) =>
                    const SizedBox(height: 120, child: Text('面板内容')),
              ),
              child: const Text('打开面板'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('桌面端：备份 zip 往返', () {
    late Directory root;
    setUp(() {
      root = Directory.systemTemp.createTempSync('xiaoji_desktop_zip_');
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('打包排除锁定条目与 tmp，解包后内容一致', () async {
      final Directory source = Directory('${root.path}/data')
        ..createSync(recursive: true);
      File('${source.path}/manifest.json').writeAsStringSync('{"v":1}');
      Directory('${source.path}/notes/2026-11').createSync(recursive: true);
      File('${source.path}/notes/2026-11/a.md').writeAsStringSync('# A');
      File('${source.path}/notes/2026-11/locked.md')
          .writeAsStringSync('secret');
      Directory('${source.path}/tmp').createSync(recursive: true);
      File('${source.path}/tmp/junk.tmp').writeAsStringSync('x');
      File('${source.path}/.hidden').writeAsStringSync('h');

      final String zipPath = '${root.path}/backup.zip';
      await zipNotesToFile(
        sourceRoot: source.path,
        targetPath: zipPath,
        excludes: <String>['notes/2026-11/locked.md'],
        overrides: <String, String>{
          'manifest.json': '${source.path}/manifest.json',
        },
      );

      final Archive archive =
          ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
      final Set<String> names =
          archive.files.map((ArchiveFile f) => f.name).toSet();
      expect(names, contains('notes/2026-11/a.md'));
      expect(names, isNot(contains('notes/2026-11/locked.md')));
      expect(names.any((String n) => n.startsWith('tmp/')), isFalse);
      expect(names.any((String n) => n.endsWith('.tmp')), isFalse);

      final Directory dest = Directory('${root.path}/restore');
      await unzipTo(zipPath: zipPath, destDir: dest.path);
      expect(
        File('${dest.path}/notes/2026-11/a.md').readAsStringSync(),
        '# A',
      );
    });

    test('解包忽略越目录条目（恶意压缩包）', () async {
      final Archive archive = Archive();
      final List<int> evil = utf8.encode('evil');
      archive.addFile(ArchiveFile('../evil.txt', evil.length, evil));
      final String zipPath = '${root.path}/evil.zip';
      File(zipPath).writeAsBytesSync(ZipEncoder().encode(archive)!);

      final String destPath = '${root.path}/restore';
      await unzipTo(zipPath: zipPath, destDir: destPath);
      expect(File('${root.path}/evil.txt').existsSync(), isFalse);
    });
  });

  group('桌面端：外置备份目录', () {
    late Directory root;
    setUp(() {
      root = Directory.systemTemp.createTempSync('xiaoji_desktop_ext_');
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('写入目录并按前缀只保留最近 N 份', () async {
      final Directory dir = Directory('${root.path}/external')..createSync();
      for (int i = 1; i <= 3; i++) {
        final File old = File('${dir.path}/xiaoji-old$i.zip')
          ..writeAsStringSync('old$i');
        old.setLastModifiedSync(DateTime(2026, 1, i));
      }
      final File src = File('${root.path}/new.zip')..writeAsStringSync('new');

      final String saved = await writeFileToTree(
        treeUri: dir.path,
        sourcePath: src.path,
        fileName: 'xiaoji-new.zip',
        keepPrefix: 'xiaoji-',
        keep: 2,
      );
      expect(File(saved).existsSync(), isTrue);
      final List<String> remain = dir
          .listSync()
          .whereType<File>()
          .map((File f) => f.uri.pathSegments.last)
          .toList()
        ..sort();
      expect(remain, <String>['xiaoji-new.zip', 'xiaoji-old3.zip']);
    });

    test('目录不存在时自动创建', () async {
      final File src = File('${root.path}/new.zip')..writeAsStringSync('x');
      final String dirPath = '${root.path}/deep/nested';
      final String saved = await writeFileToTree(
        treeUri: dirPath,
        sourcePath: src.path,
        fileName: 'xiaoji-new.zip',
      );
      expect(File(saved).existsSync(), isTrue);
    });
  });

  group('备份目录标签', () {
    test('桌面普通路径只显示末两级', () {
      expect(
        backupFolderLabel('/Users/qiwei/Documents/Backups'),
        '…/Documents/Backups',
      );
      expect(backupFolderLabel(r'C:\Users\Me\Backup'), '…/Me/Backup');
      expect(backupFolderLabel('/Backup'), 'Backup');
    });

    test('Android SAF 目录仍显示相对路径', () {
      expect(
        backupFolderLabel('content://tree/primary%3ADownload/Xiaoji'),
        'Download/Xiaoji',
      );
    });
  });

  group('平板 / 桌面宽屏布局', () {
    late Directory tempDir;
    late NoteRepository repository;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('xiaoji_wide_');
      final NoteStore store =
          await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
      repository = NoteRepository(store);
      await store.saveNote(
        Note(
          id: 'n1',
          created: DateTime(2026, 11, 1, 8),
          updated: DateTime(2026, 11, 1, 8),
          tags: const <String>['读书'],
          body: '宽屏笔记正文',
        ),
      );
      // 第二条给「↑ / ↓ 切换笔记」用：列表需要至少两项才有下一条。
      await store.saveNote(
        Note(
          id: 'n2',
          created: DateTime(2026, 11, 2, 9),
          updated: DateTime(2026, 11, 2, 9),
          body: '第二条笔记正文',
        ),
      );
      await repository.load();
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    testWidgets('1280x800 下首页不溢出，内容限宽居中', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
            theme: AppTheme.light(), home: HomePage(repository: repository)),
      );
      await _pumpFrames(tester);

      expect(tester.takeException(), isNull);
      // 列表被 ContentFrame 收窄：不会铺满 1280，但也不至于窄成手机条。
      final double listWidth =
          tester.getSize(find.byType(ListView).first).width;
      expect(listWidth, lessThanOrEqualTo(800));
      expect(listWidth, greaterThan(300));
    });

    testWidgets('平板横屏（1024x768）也启用双栏', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: HomePage(repository: repository),
        ),
      );
      await _pumpFrames(tester);

      expect(find.text('选择一条小记开始阅读'), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('手机横屏（932x430）保持单栏，不强行双栏', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.physicalSize = const Size(932, 430);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: HomePage(repository: repository),
        ),
      );
      await _pumpFrames(tester);

      expect(find.text('选择一条小记开始阅读'), findsNothing);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('窗口跨过双栏阈值时自动切换布局', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: HomePage(repository: repository),
        ),
      );
      await _pumpFrames(tester);
      expect(find.text('选择一条小记开始阅读'), findsOneWidget);

      // 拖窄到 820：低于 900 阈值，回到单栏。
      tester.view.physicalSize = const Size(820, 700);
      await _pumpFrames(tester);
      expect(find.text('选择一条小记开始阅读'), findsNothing);

      // 再拖宽：双栏恢复。
      tester.view.physicalSize = const Size(1280, 800);
      await _pumpFrames(tester);
      expect(find.text('选择一条小记开始阅读'), findsOneWidget);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('桌面宽屏：列表与详情并排，点笔记在右侧打开', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: HomePage(repository: repository),
        ),
      );
      await _pumpFrames(tester);

      // 双栏空态：列表在左，右侧提示选一条。
      expect(find.text('选择一条小记开始阅读'), findsOneWidget);
      expect(find.byType(NewEditorPage), findsNothing);

      await tester.tap(find.textContaining('宽屏笔记正文').first);
      await _pumpFrames(tester);

      // 正文嵌在右侧，列表没有消失（不是整页路由跳走）。
      expect(find.byType(NewEditorPage), findsOneWidget);
      expect(find.byType(ListView), findsWidgets);
      // 当前打开的笔记在列表里高亮（主流桌面笔记的选中态）。
      final NoteTileComfortable tile = tester.widget<NoteTileComfortable>(
        find.byWidgetPredicate(
          (Widget w) => w is NoteTileComfortable && w.note.id == 'n1',
        ),
      );
      expect(tile.selected, isTrue);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('桌面双栏：↑ / ↓ 切换当前笔记', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: HomePage(repository: repository),
        ),
      );
      await _pumpFrames(tester);

      // 先点开最新一条（n2），列表随之拿到焦点。
      await tester.tap(find.textContaining('第二条笔记正文').first);
      await _pumpFrames(tester);
      expect(
        tester.widget<NewEditorPage>(find.byType(NewEditorPage)).note.id,
        'n2',
      );

      // ↓ 切到更早的一条。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _pumpFrames(tester);
      expect(
        tester.widget<NewEditorPage>(find.byType(NewEditorPage)).note.id,
        'n1',
      );

      // ↑ 回到最新一条。
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await _pumpFrames(tester);
      expect(
        tester.widget<NewEditorPage>(find.byType(NewEditorPage)).note.id,
        'n2',
      );

      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('宽屏弹层收窄到 560 并居中', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
            theme: AppTheme.light(), home: HomePage(repository: repository)),
      );
      await _pumpFrames(tester);

      await tester.tap(find.byIcon(Icons.sell_outlined));
      await _pumpFrames(tester);

      expect(find.byType(BottomSheet), findsWidgets);
      // BottomSheet 外层仍铺满路由，真正的面板由 showXiaojiSheet 传的
      // constraints 收窄，所以断言约束值而不是外层尺寸。
      final Iterable<ConstrainedBox> boxes =
          tester.widgetList<ConstrainedBox>(find.byType(ConstrainedBox));
      expect(
        boxes.any((ConstrainedBox box) =>
            box.constraints.maxWidth == kXiaojiSheetMaxWidth),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('窄屏（手机）弹层仍铺满宽度', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
            theme: AppTheme.light(), home: HomePage(repository: repository)),
      );
      await _pumpFrames(tester);

      await tester.tap(find.byIcon(Icons.sell_outlined));
      await _pumpFrames(tester);

      expect(find.byType(BottomSheet), findsWidgets);
      final Iterable<ConstrainedBox> boxes =
          tester.widgetList<ConstrainedBox>(find.byType(ConstrainedBox));
      expect(
        boxes.any((ConstrainedBox box) =>
            box.constraints.maxWidth == kXiaojiSheetMaxWidth),
        isFalse,
      );
    });
  });

  group('桌面端：详情页交互与排版', () {
    late Directory tempDir;
    late NoteRepository repository;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('xiaoji_pc_editor_');
      final NoteStore store = await NoteStore.openAt(
        Directory('${tempDir.path}/Xiaoji'),
      );
      repository = NoteRepository(store);
      await repository.load();
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    testWidgets('点进正文后工具栏可用，Aa 面板无需软键盘即可展开', (
      WidgetTester tester,
    ) async {
      // 平台覆写必须在测试体内设置并在测试体内复位：widget 测试结束前
      // 会校验 foundation 调试变量已还原，addTearDown 的时机晚于校验。
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
              id: 'pc1',
              created: DateTime(2026, 11, 1),
              updated: DateTime(2026, 11, 1),
              body: '# 第一章\n\n桌面端正文，双击应该可以选词。\n',
            ),
          ),
        ),
      );
      await _pumpFrames(tester);

      // 桌面没有软键盘（viewInsets 恒为 0）。修复前工具条被
      // IgnorePointer 一直挡住，Aa 面板永远打不开。
      final Offset textSpot =
          tester.getTopLeft(find.byType(SuperEditor)) + const Offset(80, 120);
      await tester.tapAt(textSpot);
      await _pumpFrames(tester);
      await tester.tap(find.text('Aa'));
      await _pumpFrames(tester);

      expect(find.text('标题'), findsWidgets);
      expect(find.text('结构'), findsWidgets);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('桌面空文档：占位提示与光标对齐', (WidgetTester tester) async {
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
              id: 'pc-empty',
              created: DateTime(2026, 11, 1),
              updated: DateTime(2026, 11, 1),
            ),
            autoFocus: true,
          ),
        ),
      );
      await _pumpFrames(tester);

      final Rect placeholder = tester.getRect(
        find.byKey(const ValueKey<String>('editor-placeholder')),
      );
      final Rect caret = tester.getRect(find.byKey(xiaojiCaretKey));
      expect(caret.left, closeTo(placeholder.left, 0.5));
      expect(caret.top, greaterThanOrEqualTo(placeholder.top - 0.5));
      expect(caret.bottom, lessThanOrEqualTo(placeholder.bottom + 0.5));
      debugDefaultTargetPlatformOverride = null;
    });

    test('表格单列上限：桌面 320，手机/平板仍 240', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(tableColumnCap(availableWidth: 728, columns: 2, max: 320), 320);
      expect(tableColumnCap(availableWidth: 728, columns: 4, max: 320), 182);
      expect(tableColumnCap(availableWidth: 358, columns: 2), 179);
    });

    testWidgets('⌘= / ⌘- / ⌘0 缩放正文', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      addTearDown(resetEditorZoom);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          // 缩放快捷键挂在应用层（main.dart 的桌面快捷方式里），
          // 这里直接包住编辑页验证「按键 → 缩放值」这条链路。
          home: EditorZoomShortcuts(
            child: NewEditorPage(
              repository: repository,
              note: Note(
                id: 'pc-zoom',
                created: DateTime(2026, 11, 1),
                updated: DateTime(2026, 11, 1),
                body: '正文缩放测试\n',
              ),
            ),
          ),
        ),
      );
      await _pumpFrames(tester);

      final Offset textSpot =
          tester.getTopLeft(find.byType(SuperEditor)) + const Offset(80, 120);
      await tester.tapAt(textSpot);
      await _pumpFrames(tester);
      expect(editorZoom.value, 1.0);

      await _pressWithMeta(tester, LogicalKeyboardKey.equal);
      expect(editorZoom.value, closeTo(1.05, 1e-9));

      await _pressWithMeta(tester, LogicalKeyboardKey.minus);
      await _pressWithMeta(tester, LogicalKeyboardKey.minus);
      expect(editorZoom.value, closeTo(0.95, 1e-9));

      await _pressWithMeta(tester, LogicalKeyboardKey.digit0);
      expect(editorZoom.value, 1.0);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });

    test('缩放边界：0.85–1.4，步进 0.05，⌘0 复位', () {
      addTearDown(resetEditorZoom);
      resetEditorZoom();
      adjustEditorZoom(kEditorZoomStep);
      expect(editorZoom.value, closeTo(1.05, 1e-9));
      for (int i = 0; i < 20; i++) {
        adjustEditorZoom(kEditorZoomStep);
      }
      expect(editorZoom.value, kEditorZoomMax);
      for (int i = 0; i < 40; i++) {
        adjustEditorZoom(-kEditorZoomStep);
      }
      expect(editorZoom.value, kEditorZoomMin);
      resetEditorZoom();
      expect(editorZoom.value, 1.0);
    });

    testWidgets('桌面表格：单击单元格就地编辑，Tab 提交并切下一格', (
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
              id: 'pc-table',
              created: DateTime(2026, 11, 1),
              updated: DateTime(2026, 11, 1),
              body: '| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |',
            ),
          ),
        ),
      );
      await _pumpFrames(tester);

      // 单元格文字由 Text.rich 渲染，要开 findRichText 才找得到。
      final Finder apple = find.text('苹果', findRichText: true);
      expect(apple, findsOneWidget);

      // 单击即进入编辑（Word / 语雀 / Notion 的表格语义）：表格内容层是
      // IgnorePointer（点按交给内核），tap 命中到表格 Listener 后按坐标
      // 换算成行列。
      await tester.tap(apple, warnIfMissed: false);
      await _pumpFrames(tester);
      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), '香蕉');
      await _pumpFrames(tester, frames: 2);

      // Tab：提交并切到下一格（数量 3），表格里已经写回「香蕉」。
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await _pumpFrames(tester);
      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '3',
      );
      expect(find.text('香蕉', findRichText: true), findsOneWidget);

      // Esc：取消编辑，不留在编辑态。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _pumpFrames(tester);
      expect(find.byType(TextField), findsNothing);
      // 表格重建后选区收敛到表格块：不残留错位的文本光标（用户反馈）。
      expect(find.byKey(xiaojiCaretKey), findsNothing);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('桌面大面板（历史版本等）用居中对话框', (
      WidgetTester tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await _pumpPanelHost(tester);
      await tester.tap(find.text('打开面板'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('面板内容'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('移动端大面板仍是底部弹层', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await _pumpPanelHost(tester);
      await tester.tap(find.text('打开面板'));
      await tester.pumpAndSettle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('桌面表格铺满正文宽度，不再按内容收缩', (
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
              id: 'pc-table-fill',
              created: DateTime(2026, 11, 1),
              updated: DateTime(2026, 11, 1),
              body: '| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |',
            ),
          ),
        ),
      );
      await _pumpFrames(tester);

      final Size table = tester.getSize(find.byType(Table));
      // 正文列宽 760，扣掉页边距后表格应铺满（而不是按内容缩到一百多）。
      expect(table.width, greaterThan(600));
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('桌面表格：单击即进入编辑，Esc 退出', (
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
              id: 'pc-table-single-tap',
              created: DateTime(2026, 11, 1),
              updated: DateTime(2026, 11, 1),
              body: '| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |',
            ),
          ),
        ),
      );
      await _pumpFrames(tester);

      // 单击一次即进入编辑框，单元格里的文字可以拖选 / ⌘C 复制。
      await tester.tap(
        find.text('苹果', findRichText: true),
        warnIfMissed: false,
      );
      await _pumpFrames(tester);
      expect(find.byType(TextField), findsOneWidget);

      // Esc 退出编辑，不留下编辑框。
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _pumpFrames(tester);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
