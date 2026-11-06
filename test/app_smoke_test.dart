import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/editor/editor_page.dart';
import 'package:xiaoji/editor/lab/new_editor_page.dart';
import 'package:xiaoji/editor/markdown_toolbar.dart';
import 'package:xiaoji/editor/markdown_view.dart';
import 'package:xiaoji/editor/markdown_controller.dart';
import 'package:xiaoji/editor/widgets/image_block_view.dart';
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
  group('MarkdownEditingController 只改样式不改文本', () {
    const samples = <String>[
      '# 标题一级\n## 标题二级\n###### 标题六级',
      '普通一段 **粗体** 与 *斜体* 和 `行内码`',
      '- [ ] 待办\n- [x] 已完成\n- 无序\n1. 有序',
      '> 引用一段\n\n---\n\n正文',
      '```dart\nvoid main() {}\n```',
      '看这里 [链接](https://example.com) 和 #标签 ~~删除线~~',
      '![](assets/x/1.jpg)\n[a.pdf](assets/x/a.pdf)',
      '',
      '结尾没有换行',
      '结尾有换行\n',
      '没有闭合的 **粗体 和 *斜体 和 `code',
    ];

    testWidgets('拼出来的 span 文本与原始 markdown 完全一致', (WidgetTester tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (BuildContext context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      for (final sample in samples) {
        final controller = MarkdownEditingController(text: sample);
        final span = controller.buildTextSpan(
          context: captured,
          style: const TextStyle(fontSize: 15),
          withComposing: false,
        );
        expect(
          span.toPlainText(),
          sample,
          reason: '样本「$sample」的渲染文本与原文不一致，会导致光标错位',
        );
        controller.dispose();
      }
    });

    testWidgets('组词期间退回默认实现，不破坏输入法', (WidgetTester tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (BuildContext context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final controller = MarkdownEditingController(text: 'zhongwen');
      controller.value = const TextEditingValue(
        text: 'zhongwen',
        selection: TextSelection.collapsed(offset: 8),
        composing: TextRange(start: 0, end: 8),
      );

      final span = controller.buildTextSpan(
        context: captured,
        style: const TextStyle(fontSize: 15),
        withComposing: true,
      );
      expect(span.toPlainText(), 'zhongwen');
      controller.dispose();
    });
  });

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

      await tester.tap(find.byIcon(Icons.edit_outlined));
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
      expect(find.byIcon(Icons.close), findsNothing);

      // 激活筛选：标题栏原位出现胶囊（卡片标签 + 标题栏胶囊各一个）。
      repository.setActiveTag('想法');
      await _pumpFrames(tester);
      expect(find.text('#想法'), findsNWidgets(2));
      expect(find.byIcon(Icons.close), findsOneWidget);

      // 点胶囊上的 × 直接清除筛选。
      await tester.tap(find.byIcon(Icons.close));
      await _pumpFrames(tester);
      expect(repository.activeTag, isNull);
      expect(find.text('#想法'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);
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
      expect(find.byIcon(Icons.push_pin), findsOneWidget);
    });

    testWidgets('编辑态键盘未弹出时工具栏滑出屏幕且不占布局', (WidgetTester tester) async {
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
            id: 'tb1',
            created: DateTime(2026, 10, 31, 9, 12),
            updated: DateTime(2026, 10, 31, 9, 20),
            body: '工具栏占位',
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

      // 进编辑态（widget 测试里没有真实 IME，viewInsets 恒为 0）。
      await tester.tap(find.byType(MarkdownBlockView).first);
      // 220ms 出入场动画 + 600ms 延时聚焦回调都要走完。
      await _pumpFrames(tester, frames: 16);

      // 工具条现在是贴在键盘上沿的浮层（Positioned），键盘没弹时滑出屏幕、
      // 且不参与布局 —— 正文底部不会因此多出死空间。
      expect(find.byType(MarkdownToolbar), findsOneWidget);
      final toolbarSlide = tester.widget<AnimatedSlide>(
        find.ancestor(
          of: find.byType(MarkdownToolbar),
          matching: find.byType(AnimatedSlide),
        ).first,
      );
      expect(toolbarSlide.offset, const Offset(0, 1));

      // 内容区高度必须与「浏览器」时一致：键盘是浮层，不能改变列表布局。
      final listHeight = tester.getSize(find.byType(ListView).first).height;
      expect(listHeight, greaterThan(0));
      expect(
        tester.getBottomLeft(find.byType(MarkdownToolbar)).dy,
        greaterThanOrEqualTo(
          tester.getBottomLeft(find.byType(ListView).first).dy,
        ),
        reason: '工具栏应该滑到内容区下沿之外',
      );
    });

    testWidgets('编辑页把正文渲染成可编辑文本块', (WidgetTester tester) async {
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
      });

      final note = Note(
        id: '20261031-0912-a1b2',
        created: DateTime(2026, 10, 31, 9, 12, 33),
        updated: DateTime(2026, 10, 31, 9, 12, 33),
        body: '第一段',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: EditorPage(repository: repository, note: note),
        ),
      );
      await _pumpFrames(tester, frames: 10);

      // 已有笔记打开是阅读态：没有输入框，正文以渲染结果呈现。
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byType(MarkdownBlockView).first);
      await _pumpFrames(tester, frames: 3);

      final field = tester.widget<TextField>(find.byType(TextField).first);
      expect(field.controller?.text, '第一段');

      await tester.enterText(find.byType(TextField).first, '第一段\n第二段');
      await _pumpFrames(tester, frames: 2);

      // 单态 + 语雀语义：块中回车 = 拆块。聚焦块是「第二段」，
      // 「第一段」留在前面的渲染块里。
      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '第二段',
      );
      expect(
        tester.widget<MarkdownBlockView>(find.byType(MarkdownBlockView).first)
            .text,
        '第一段',
      );
    });

    testWidgets('中文输入法批量提交换行后，有序列表仍然续号', (WidgetTester tester) async {
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
      });

      final note = Note(
        id: 'ime-ordered',
        created: DateTime(2026, 10, 31, 9, 12, 33),
        updated: DateTime(2026, 10, 31, 9, 12, 33),
        body: '1. hello',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: EditorPage(repository: repository, note: note),
        ),
      );
      await _pumpFrames(tester, frames: 10);
      await tester.tap(find.byType(MarkdownBlockView).first);
      await _pumpFrames(tester, frames: 6);

      // 模拟中文输入法的批量提交：组词「世界」上屏和换行合并成一次
      // 更新（文本 +N，而不是 +1）。旧实现只认严格 +1，换行会留在
      // 块内，列表续号随之失效（用户实测）。
      final controller =
          tester.widget<TextField>(find.byType(TextField).first).controller!;
      controller.value = const TextEditingValue(
        text: '1. hello世界\n',
        selection: TextSelection.collapsed(offset: 11),
      );
      await _pumpFrames(tester, frames: 4);

      // 单态：同一时刻只有聚焦块是 TextField。回车后新块「2. 」接管聚焦，
      // 旧块转回渲染态。
      expect(find.byType(TextField), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        '2. ',
      );
      final rendered =
          tester.widget<MarkdownBlockView>(find.byType(MarkdownBlockView).first);
      expect(rendered.text, '1. hello世界');
    });

    testWidgets('阅读态点击正文，光标落在点击位置附近而不是块尾', (WidgetTester tester) async {
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
      });

      const body = '这是一段足够长的正文内容，用来验证点击定位光标的功能。';
      final note = Note(
        id: 'tap-caret',
        created: DateTime(2026, 10, 31, 9, 12, 33),
        updated: DateTime(2026, 10, 31, 9, 12, 33),
        body: body,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: EditorPage(repository: repository, note: note),
        ),
      );
      await _pumpFrames(tester, frames: 10);

      // 点文本中段：取正文块里 RenderParagraph 的几何中心
      // （纯文本块的中心就是文字中点）。注意第一个 RichText 是顶栏
      // 时间的，必须取 MarkdownBlockView 内部的。
      final paragraph = tester.renderObject<RenderParagraph>(
        find
            .descendant(
              of: find.byType(MarkdownBlockView),
              matching: find.byType(RichText),
            )
            .first,
      );
      final mid = paragraph.localToGlobal(
        Offset(paragraph.size.width / 2, paragraph.size.height / 2),
      );
      await tester.tapAt(mid);
      await _pumpFrames(tester, frames: 6);

      expect(find.byType(TextField), findsOneWidget);
      final controller =
          tester.widget<TextField>(find.byType(TextField).first).controller!;
      // 光标应该在点击处附近（中段），而不是块尾（旧实现落末尾）。
      expect(controller.selection.baseOffset, lessThan(body.length));
      expect(controller.selection.baseOffset, greaterThan(0));
    });

    testWidgets('阅读态点击待办勾选框直接翻转，不进编辑态', (WidgetTester tester) async {
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
      });

      final note = Note(
        id: 'read-todo',
        created: DateTime(2026, 10, 31, 9, 12, 33),
        updated: DateTime(2026, 10, 31, 9, 12, 33),
        body: '- [ ] 买牛奶\n- [x] 已完成',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: EditorPage(repository: repository, note: note),
        ),
      );
      await _pumpFrames(tester, frames: 10);

      // 阅读态：待办渲染成真 checkbox 图标（一行一个：1 空 + 1 勾）。
      expect(find.byType(TextField), findsNothing);
      expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
      expect(find.byIcon(Icons.check_box), findsOneWidget);

      // 点未勾选的勾选框：原地翻转，不进编辑态。
      await tester.tap(find.byIcon(Icons.check_box_outline_blank).first);
      await _pumpFrames(tester, frames: 4);
      expect(find.byType(TextField), findsNothing);
      expect(find.byIcon(Icons.check_box), findsNWidgets(2));
      expect(find.byIcon(Icons.check_box_outline_blank), findsNothing);

      // 再点「买牛奶」的勾选框翻回去。
      await tester.tap(find.byIcon(Icons.check_box).first);
      await _pumpFrames(tester, frames: 4);
      expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
      expect(find.byIcon(Icons.check_box), findsOneWidget);
    });

    testWidgets('粘贴 markdown 自动识别：图片行独立成块', (WidgetTester tester) async {
      final tempDir = Directory.systemTemp.createTempSync('xiaoji_ui_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      // mock 系统剪贴板（测试环境没有平台通道实现）。
      // hasStrings 必须返回 true，否则系统长按菜单不显示「粘贴」项。
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.getData') {
            return const <String, dynamic>{
              'text': '来自网页的一段文字\n![](assets/n1/1.jpg)\n',
            };
          }
          if (call.method == 'Clipboard.hasStrings') {
            return const <String, dynamic>{'value': true};
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });

      late NoteRepository repository;
      await tester.runAsync(() async {
        final store =
            await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
        repository = NoteRepository(store);
      });

      final note = Note(
        id: 'paste-md',
        created: DateTime(2026, 10, 31, 9, 12, 33),
        updated: DateTime(2026, 10, 31, 9, 12, 33),
        body: '原有内容',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: EditorPage(repository: repository, note: note),
        ),
      );
      await _pumpFrames(tester, frames: 10);
      await tester.tap(find.byType(MarkdownBlockView).first);
      await _pumpFrames(tester, frames: 6);

      // 长按正文：选中一个词并弹出**系统样式**菜单（默认英文本地化），
      // 点其中的 Paste —— 它已被接管为 markdown 识别粘贴。
      await tester.longPress(find.byType(TextField));
      await _pumpFrames(tester, frames: 4);
      await tester.tap(find.text('Paste'));
      await _pumpFrames(tester, frames: 6);

      // 图片行被识别成独立图片块；文字并入正文块。
      expect(find.byType(ImageBlockView), findsOneWidget);
      final focused =
          tester.widget<TextField>(find.byType(TextField)).controller?.text;
      expect(focused, contains('来自网页的一段文字'));
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
