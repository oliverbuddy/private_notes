import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/editor/lab/new_editor_page.dart';
import 'package:xiaoji/home/home_page.dart';
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

    test('表格单列上限：桌面 320，手机/平板仍 240', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(tableColumnCap(availableWidth: 728, columns: 2, max: 320), 320);
      expect(tableColumnCap(availableWidth: 728, columns: 4, max: 320), 182);
      expect(tableColumnCap(availableWidth: 358, columns: 2), 179);
    });
  });
}
