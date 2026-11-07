import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/editor/lab/new_editor_page.dart';
import 'package:xiaoji/home/home_page.dart';
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/theme/app_theme.dart';

/// 这个文件有两条纪律：
///
/// 1. widget 测试跑在 fakeAsync 里，真实文件 I/O 的 Future 永远不会完成，
///    所以所有落盘动作都放进 `tester.runAsync`；纯存储逻辑用 `test()` 覆盖。
/// 2. 编辑页有 autofocus 输入框，光标闪烁会无限排帧，所以不用 pumpAndSettle，
///    一律显式 pump。
Future<void> _pumpFrames(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  group('界面渲染', () {
    testWidgets('空列表显示空状态，点 FAB 能进编辑页', (WidgetTester tester) async {
      final tempDir = Directory.systemTemp.createTempSync('xiaoji_ui_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      late NoteRepository repository;
      await tester.runAsync(() async {
        final store =
            await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
        repository = NoteRepository(store);
        await repository.load();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: HomePage(repository: repository),
        ),
      );
      await _pumpFrames(tester);

      expect(find.text('还没有小记'), findsOneWidget);
      expect(find.text('点右下角的笔开始'), findsOneWidget);
      // 标签筛选收进标题栏：未选中标签时不再渲染常驻 chips（第 7 轮改版）。
      expect(find.text('全部'), findsNothing);

      await tester.tap(find.byIcon(Icons.edit_rounded));
      await _pumpFrames(tester, frames: 12);
      // 内核迁移：编辑入口已全量切换到新内核编辑页。
      expect(find.byType(NewEditorPage), findsOneWidget);
    });

    testWidgets('激活标签筛选后标题栏出现胶囊，点 × 清除', (WidgetTester tester) async {
      final tempDir = Directory.systemTemp.createTempSync('xiaoji_ui_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      late NoteRepository repository;
      await tester.runAsync(() async {
        final store =
            await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
        repository = NoteRepository(store);
        await repository.load();
        await repository.upsert(
          Note(
            id: 'tag1',
            created: DateTime(2026, 10, 31, 9, 12),
            updated: DateTime(2026, 10, 31, 9, 20),
            tags: const <String>['想法'],
            body: '第一条',
          ),
        );
        // 本用例只验证标签胶囊的 ×；关掉主页一次性备份提示，
        // 否则它自带的关闭图标会干扰 find.byIcon(Icons.close_rounded)。
        await repository.updateSettings(
          repository.settings.copyWith(backupTipShown: true),
        );
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: HomePage(repository: repository),
        ),
      );
      await _pumpFrames(tester);

      // 未筛选：没有筛选条，也没有标题栏胶囊。
      expect(find.text('#想法'), findsOneWidget); // 只有笔记卡片上的标签
      expect(find.byIcon(Icons.close_rounded), findsNothing);

      // 激活筛选：标题栏原位出现胶囊（卡片标签 + 标题栏胶囊各一个）。
      repository.setActiveTag('想法');
      await _pumpFrames(tester);
      expect(find.text('#想法'), findsNWidgets(2));
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);

      // 点胶囊上的 × 直接清除筛选。
      await tester.tap(find.byIcon(Icons.close_rounded));
      await _pumpFrames(tester);
      expect(repository.activeTag, isNull);
      expect(find.text('#想法'), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsNothing);
    });

    testWidgets('主页显示摘要、标签与置顶标记', (WidgetTester tester) async {
      final tempDir = Directory.systemTemp.createTempSync('xiaoji_ui_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      late NoteRepository repository;
      await tester.runAsync(() async {
        final store =
            await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
        repository = NoteRepository(store);
        await repository.load();
        await repository.upsert(
          Note(
            id: 'n1',
            created: DateTime(2026, 10, 31, 9, 12),
            updated: DateTime(2026, 10, 31, 9, 20),
            tags: const <String>['想法'],
            pinned: true,
            body: '# 今天的想法\n\n**很重要** 的事',
          ),
        );
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: HomePage(repository: repository),
        ),
      );
      await _pumpFrames(tester);

      // 摘要用 Text.rich 渲染（为了搜索高亮），按纯文本断言。
      // 正文里的空行会切成两段（中间留一行空隙），所以标题与正文是
      // 两个 Text —— 空行不能被吃掉（用户反复强调）。
      expect(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is Text &&
              (widget.textSpan?.toPlainText() ?? widget.data ?? '') ==
                  '今天的想法',
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is Text &&
              (widget.textSpan?.toPlainText() ?? widget.data ?? '')
                  .contains('很重要 的事'),
        ),
        findsOneWidget,
      );
      expect(find.text('#想法'), findsOneWidget);
      expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
    });

  });

  group('存储与仓库（真实文件 I/O）', () {
    test('保存后能原样读回', () async {
      final tempDir = await Directory.systemTemp.createTemp('xiaoji_store_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final store = await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
      final note = Note(
        id: '20261031-0912-a1b2',
        created: DateTime(2026, 10, 31, 9, 12, 33),
        updated: DateTime(2026, 10, 31, 9, 15, 10),
        tags: const <String>['旅行', '想法'],
        pinned: true,
        body: '# 标题\n\n正文 **粗体**\n![](assets/20261031-0912-a1b2/1.jpg)',
      );
      await store.saveNote(note);

      final loaded = await store.loadNotes();
      expect(loaded.length, 1);
      expect(loaded.first.id, note.id);
      expect(loaded.first.body, note.body);
      expect(loaded.first.tags, note.tags);
      expect(loaded.first.pinned, isTrue);

      // 落盘路径要按年/月分目录
      expect(
        store.pathFor(note).endsWith(
              'notes/2026/10/20261031-0912-a1b2.md',
            ),
        isTrue,
      );
    });

    test('坏文件被跳过，不影响其他笔记', () async {
      final tempDir = await Directory.systemTemp.createTemp('xiaoji_bad_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final store = await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
      final good = Note(
        id: 'good',
        created: DateTime(2026, 10, 31, 9, 12),
        updated: DateTime(2026, 10, 31, 9, 12),
        body: '好的',
      );
      await store.saveNote(good);

      final broken = File('${store.notesDir.path}/2026/10/broken.md');
      await broken.parent.create(recursive: true);
      await broken.writeAsString('这不是 frontmatter');

      final loaded = await store.loadNotes();
      expect(loaded.length, 1);
      expect(loaded.first.id, 'good');
    });

    test('附件按序号递增命名，路径为相对路径', () async {
      final tempDir = await Directory.systemTemp.createTemp('xiaoji_asset_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final store = await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
      final source = File('${tempDir.path}/photo.png');
      await source.writeAsBytes(<int>[1, 2, 3]);

      final first = await store.importAttachment(
        noteId: 'n1',
        sourcePath: source.path,
      );
      final second = await store.importAttachment(
        noteId: 'n1',
        sourcePath: source.path,
      );
      expect(first, 'assets/n1/1.png');
      expect(second, 'assets/n1/2.png');
      expect(File(store.absoluteAssetPath(first)).existsSync(), isTrue);
    });

    test('删除把正文和附件整体移进回收站，可撤销恢复', () async {
      final tempDir = await Directory.systemTemp.createTemp('xiaoji_del_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final store = await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
      final repository = NoteRepository(store);
      await repository.load();

      final note = Note(
        id: 'del-1',
        created: DateTime(2026, 10, 31, 9, 12),
        updated: DateTime(2026, 10, 31, 9, 12),
        body: '待删除',
      );
      await repository.upsert(note);

      final source = File('${tempDir.path}/source.jpg');
      await source.writeAsBytes(<int>[1, 2, 3]);
      await store.importAttachment(noteId: note.id, sourcePath: source.path);

      await repository.remove(note);
      expect(repository.notes, isEmpty);
      // 附件目录不再被直接删掉：它跟着正文一起进了 trash/<id>/assets。
      expect(store.assetDirectoryOf(note.id).existsSync(), isFalse);
      final trash = await repository.loadTrash();
      expect(trash, hasLength(1));
      expect(trash.single.hasAssets, isTrue);
      expect(store.trashDir.listSync().isNotEmpty, isTrue);

      // 撤销删除：正文与附件都回到原位。
      expect(await repository.undoDelete(note.id), isTrue);
      expect(repository.notes.single.id, note.id);
      expect(store.assetDirectoryOf(note.id).existsSync(), isTrue);
      expect(await repository.loadTrash(), isEmpty);
    });

    test('设置读写与默认值', () async {
      final tempDir = await Directory.systemTemp.createTemp('xiaoji_set_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final store = await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
      final defaults = await store.loadSettings();
      expect(defaults.theme.label, '跟随系统');
      expect(defaults.density.label, '舒适');
    });
  });

  group('NoteRepository 排序与筛选', () {
    test('置顶优先，其余按 updated 倒序', () async {
      final tempDir = await Directory.systemTemp.createTemp('xiaoji_repo_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final store = await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
      final repository = NoteRepository(store);
      await repository.load();

      final now = DateTime.now();
      await repository.upsert(
        Note(id: 'a', created: now, updated: now, body: '最新的普通笔记'),
      );
      await repository.upsert(
        Note(
          id: 'b',
          created: now,
          updated: now.subtract(const Duration(days: 1)),
          body: '较早的置顶笔记',
          pinned: true,
        ),
      );
      await repository.upsert(
        Note(
          id: 'c',
          created: now,
          updated: now.subtract(const Duration(hours: 1)),
          body: '稍早的普通笔记',
        ),
      );

      expect(
        repository.visibleNotes.map((Note item) => item.id).toList(),
        <String>['b', 'a', 'c'],
      );

      repository.setActiveTag('想法');
      expect(repository.visibleNotes, isEmpty);
      repository.setActiveTag(null);

      repository.setQuery('稍早');
      expect(repository.isSearching, isTrue);
      expect(
        repository.visibleNotes.map((Note item) => item.id).toList(),
        <String>['c'],
      );

      repository.setQuery('');
      expect(repository.visibleNotes.length, 3);
    });

    test('标签按出现次数排序', () async {
      final tempDir = await Directory.systemTemp.createTemp('xiaoji_tags_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final store = await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
      final repository = NoteRepository(store);
      await repository.load();

      final now = DateTime.now();
      await repository.upsert(
        Note(
          id: 't1',
          created: now,
          updated: now,
          tags: const <String>['想法', '旅行'],
          body: '一',
        ),
      );
      await repository.upsert(
        Note(
          id: 't2',
          created: now,
          updated: now,
          tags: const <String>['想法'],
          body: '二',
        ),
      );

      expect(repository.tags.first, '想法');
    });
  });
}
