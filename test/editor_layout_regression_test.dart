import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/editor/lab/caret_overlay.dart';
import 'package:xiaoji/editor/lab/editor_request_handlers.dart';
import 'package:xiaoji/editor/lab/list_style.dart';
import 'package:xiaoji/editor/lab/new_editor_page.dart';
import 'package:xiaoji/editor/lab/xiaoji_markdown.dart';
import 'package:xiaoji/editor/markdown_view.dart' show CodeBlockCardStyle;
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/theme/app_theme.dart';
import 'package:xiaoji/ui/quote_block.dart';

/// 详情页排版与编辑语义的行为回归。
///
/// 覆盖本轮用户反馈的几类问题：
///  - 引用块末尾回车要继续引用，空行再回车才退出；
///  - 附件行（文本 + 卡片外观）回车/退格不能抛异常；
///  - 无序/有序/待办三类行的正文左缘一致；
///  - 空文档占位提示与光标同一行盒。
Future<void> _pumpFrames(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 建一个基于真实临时目录的仓库（widget 测试里文件 I/O 必须走 runAsync）。
Future<NoteRepository> _createRepository(
  WidgetTester tester,
  String prefix,
) async {
  final Directory tempDir = Directory.systemTemp.createTempSync(prefix);
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

Widget _buildEditor(NoteRepository repository, Note note,
    {bool autoFocus = true}) {
  return MaterialApp(
    theme: AppTheme.light(),
    home: NewEditorPage(
      repository: repository,
      note: note,
      autoFocus: autoFocus,
    ),
  );
}

Note _note(String id, String body) {
  return Note(
    id: id,
    created: DateTime(2026, 11, 2, 10),
    updated: DateTime(2026, 11, 2, 10),
    body: body,
  );
}

void main() {
  group('表格列宽适配手机窄屏', () {
    test('列数少时按可用宽度均分，铺满一屏', () {
      // 360dp 手机、正文左右各 18dp 页边距 → 可用 324。
      expect(tableColumnCap(availableWidth: 324, columns: 2), 162);
      expect(tableColumnCap(availableWidth: 324, columns: 3), 108);
    });

    test('列很多时单列不低于下限，靠横向滚动兜底', () {
      expect(tableColumnCap(availableWidth: 324, columns: 6), 96);
    });

    test('平板/PC 单列不超过上限，避免一行字拉得过长', () {
      expect(tableColumnCap(availableWidth: 800, columns: 2), 240);
    });
  });

  group('引用块回车续行', () {
    test('有内容的引用行末尾回车，新行仍然是引用', () {
      final MutableDocument document = deserializeXiaojiMarkdown('> 引用一行');
      final MutableDocumentComposer composer = MutableDocumentComposer();
      final Editor editor =
          createXiaojiEditor(document: document, composer: composer);
      final TextNode node = document.getNodeAt(0)! as TextNode;
      composer.setSelectionWithReason(
        DocumentSelection.collapsed(
          position: DocumentPosition(
            nodeId: node.id,
            nodePosition: TextNodePosition(offset: node.text.length),
          ),
        ),
      );

      editor.execute(<EditRequest>[InsertNewlineAtCaretRequest()]);

      // 文档末尾始终有一个空段落（保证底部可点），所以看「引用行之后
      // 的第一个块」而不是总节点数。
      final DocumentNode second = document.getNodeAt(1)!;
      expect(
        second.getMetadataValue(NodeMetadata.blockType),
        blockquoteAttribution,
        reason: '末尾回车要把块类型带到新行，否则引用块从第二行就断掉',
      );
    });

    test('空引用行再回车，退出引用变成普通段落', () {
      final MutableDocument document = deserializeXiaojiMarkdown('> 引用一行');
      final MutableDocumentComposer composer = MutableDocumentComposer();
      final Editor editor =
          createXiaojiEditor(document: document, composer: composer);
      final TextNode node = document.getNodeAt(0)! as TextNode;

      // 先把这一行清空，模拟「用户在本行删光了内容」。
      composer.setSelectionWithReason(
        DocumentSelection(
          base: DocumentPosition(
            nodeId: node.id,
            nodePosition: const TextNodePosition(offset: 0),
          ),
          extent: DocumentPosition(
            nodeId: node.id,
            nodePosition: TextNodePosition(offset: node.text.length),
          ),
        ),
      );
      editor.execute(<EditRequest>[
        const DeleteSelectionRequest(TextAffinity.downstream),
      ]);

      editor.execute(<EditRequest>[InsertNewlineAtCaretRequest()]);

      final DocumentNode first = document.getNodeAt(0)!;
      expect(
        first.getMetadataValue(NodeMetadata.blockType),
        paragraphAttribution,
        reason: '空引用行回车应当退出引用',
      );
    });

    testWidgets('回车续行的两个引用段渲染成一整块（中间没有缝）', (WidgetTester tester) async {
      final NoteRepository repository =
          await _createRepository(tester, 'xiaoji_quote_merge_');
      await tester.pumpWidget(
        _buildEditor(repository, _note('quote', '> 引用一行')),
      );
      await _pumpFrames(tester, frames: 12);

      // 光标落到引用行末尾，回车续行（文档里变成两个相邻的引用段落）。
      final Rect textRect = tester.getRect(
        find.textContaining('引用一行', findRichText: true).first,
      );
      await tester.tapAt(Offset(textRect.right - 1, textRect.center.dy));
      await _pumpFrames(tester, frames: 6);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _pumpFrames(tester, frames: 8);

      final Finder quotes = find.byType(QuoteBlock);
      expect(quotes, findsNWidgets(2), reason: '回车后应有两个引用段落');
      final Rect first = tester.getRect(quotes.at(0));
      final Rect second = tester.getRect(quotes.at(1));
      expect(
        (second.top - first.bottom).abs(),
        lessThan(1),
        reason: '相邻引用段必须严丝合缝，否则看起来是两个独立引用框',
      );
    });
  });

  group('附件行编辑', () {
    testWidgets('附件行回车/退格不抛异常，也不丢附件文本', (WidgetTester tester) async {
      final NoteRepository repository =
          await _createRepository(tester, 'xiaoji_attach_');
      final Note note = _note('attach', '[a.pdf](assets/attach/a.pdf)');
      await tester.pumpWidget(_buildEditor(repository, note));
      await _pumpFrames(tester, frames: 12);

      // 光标默认落在附件行行首；回车拆行、退格删字都不应该让
      // BoxComponent 的位置类型冲突（历史 bug：每帧抛异常、页面卡死）。
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _pumpFrames(tester, frames: 6);
      expect(tester.takeException(), isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await _pumpFrames(tester, frames: 6);
      expect(tester.takeException(), isNull);
    });
  });

  group('列表记号对齐', () {
    testWidgets('无序 / 有序 / 待办三类行的正文左缘一致', (WidgetTester tester) async {
      final NoteRepository repository =
          await _createRepository(tester, 'xiaoji_list_');
      final Note note = _note('lists', '- 无序\n1. 有序\n- [ ] 待办');
      await tester.pumpWidget(_buildEditor(repository, note));
      await _pumpFrames(tester, frames: 12);

      final List<double> textLefts = <double>[];
      for (final String label in <String>['无序', '有序', '待办']) {
        final Finder textFinder =
            find.textContaining(label, findRichText: true);
        expect(textFinder, findsWidgets, reason: '找不到列表行「$label」');
        textLefts.add(tester.getTopLeft(textFinder.first).dx);
      }

      // 三类行的正文起点必须一样；容差留给字体度量取整。
      for (final double left in textLefts) {
        expect(
          left,
          closeTo(textLefts.first, 0.5),
          reason: '无序/有序/待办的正文左缘不一致：$textLefts',
        );
      }
      // 记号列宽不能是 0：官方任务缩进在 indent=0 时返回 0，正文会贴到行首。
      expect(
        textLefts.first,
        greaterThan(AppSpace.page + AppListMarker.columnWidth),
      );
    });
  });

  group('块间空行与末尾空白', () {
    test('附件与图片之间的空行，存盘再读仍然保留', () {
      const String body = '[a.pdf](assets/n/a.pdf)\n\n![](assets/n/1.jpg)';
      final MutableDocument first = deserializeXiaojiMarkdown(body);

      expect(
        first.getNodeAt(1),
        isA<ParagraphNode>(),
        reason: '空行要解析成一个空段落，否则详情页里直接消失',
      );
      expect((first.getNodeAt(1)! as TextNode).text.isEmpty, isTrue);

      // 再序列化 → 再解析，空行仍然在（往返稳定）。
      final String saved = serializeDocumentToXiaojiMarkdown(first);
      expect(saved, contains('\n\n'));
      final MutableDocument second = deserializeXiaojiMarkdown(saved);
      expect((second.getNodeAt(1)! as TextNode).text.isEmpty, isTrue);
      expect(serializeDocumentToXiaojiMarkdown(second), saved);
    });

    test('末尾块是图片时，文档尾部仍有一个可落光标的空段落', () {
      final MutableDocument document =
          deserializeXiaojiMarkdown('![](assets/n/1.jpg)');
      final DocumentNode last = document.getNodeAt(document.nodeCount - 1)!;
      expect(last, isA<ParagraphNode>());
      expect((last as TextNode).text.isEmpty, isTrue);

      // 这个空段落只是编辑期的便利，不写盘。
      final String saved = serializeDocumentToXiaojiMarkdown(document);
      expect(saved, '![](assets/n/1.jpg)');
    });
  });

  group('空文档占位', () {
    testWidgets('占位提示与光标在同一行盒内，左缘一致', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);

      final NoteRepository repository =
          await _createRepository(tester, 'xiaoji_empty_');
      await tester.pumpWidget(_buildEditor(repository, _note('empty', '')));
      await _pumpFrames(tester, frames: 12);

      final Rect placeholder = tester.getRect(find.text('开始记录…'));
      final Finder caretFinder = find.byKey(xiaojiCaretKey);
      expect(caretFinder, findsOneWidget);
      final Rect caret = tester.getRect(caretFinder);

      expect(caret.left, closeTo(placeholder.left, 0.5));
      expect(caret.top, greaterThanOrEqualTo(placeholder.top - 0.5));
      expect(caret.bottom, lessThanOrEqualTo(placeholder.bottom + 0.5));
      // 光标高度按字号收，不能是整行行盒（26dp）。
      expect(caret.height, lessThan(placeholder.height));
      expect(caret.width, closeTo(1.0, 0.01));
    });
  });

  group('表格渲染', () {
    testWidgets('表格节点渲染成网格，不落到未知块', (WidgetTester tester) async {
      final NoteRepository repository =
          await _createRepository(tester, 'xiaoji_table_');
      await tester.pumpWidget(
        _buildEditor(
          repository,
          _note('table', '| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |'),
          autoFocus: false,
        ),
      );
      await _pumpFrames(tester, frames: 12);

      expect(find.byType(MarkdownTableComponent), findsOneWidget);
      expect(find.byType(UnknownComponent), findsNothing);
    });
  });

  group('行内样式渲染（详情页）', () {
    // 直接检查 SuperText 的 richText span：这是编辑态真正画到屏幕上的样式，
    // 能捕获「样式表规则被静默丢弃」这类只在渲染层暴露的问题。
    // SuperText 未由 super_editor 导出，只能用运行时类型名取 Widget 再动态读。
    List<TextSpan> collectSpans(WidgetTester tester) {
      final List<TextSpan> spans = <TextSpan>[];
      void walk(InlineSpan span) {
        if (span is TextSpan) {
          spans.add(span);
          for (final InlineSpan child
              in span.children ?? const <InlineSpan>[]) {
            walk(child);
          }
        }
      }

      for (final Widget widget in tester.widgetList(find.byWidgetPredicate(
        (Widget w) => w.runtimeType.toString() == 'SuperText',
      ))) {
        final dynamic dynamicWidget = widget;
        walk(dynamicWidget.richText as InlineSpan);
      }
      return spans;
    }

    testWidgets('==高亮== 与 `行内码` 在详情页都带样式', (WidgetTester tester) async {
      final NoteRepository repository =
          await _createRepository(tester, 'xiaoji_inline_');
      await tester.pumpWidget(
        _buildEditor(
          repository,
          _note('inline', '普通 ==高亮== 与 `行内码` 内容'),
          autoFocus: false,
        ),
      );
      await _pumpFrames(tester, frames: 12);

      final List<TextSpan> spans = collectSpans(tester);
      final TextSpan highlight = spans.firstWhere(
        (TextSpan s) => s.text == '高亮',
        orElse: () => const TextSpan(),
      );
      expect(highlight.style?.backgroundColor, isNotNull,
          reason: '高亮必须在详情页可见（背景色不能丢）');

      final TextSpan code = spans.firstWhere(
        (TextSpan s) => s.text == '行内码',
        orElse: () => const TextSpan(),
      );
      expect(code.style?.fontFamily, 'monospace', reason: '行内码必须是等宽字体');
      expect(code.style?.backgroundColor, isNotNull, reason: '行内码必须有浅底');
    });

    testWidgets('列表项里的行内样式同样生效', (WidgetTester tester) async {
      final NoteRepository repository =
          await _createRepository(tester, 'xiaoji_inline_list_');
      await tester.pumpWidget(
        _buildEditor(
          repository,
          _note('inline_list', '- 项目 ==重点== 与 `码`'),
          autoFocus: false,
        ),
      );
      await _pumpFrames(tester, frames: 12);

      final List<TextSpan> spans = collectSpans(tester);
      final TextSpan highlight = spans.firstWhere(
        (TextSpan s) => s.text == '重点',
        orElse: () => const TextSpan(),
      );
      expect(highlight.style?.backgroundColor, isNotNull,
          reason: '列表项里的高亮同样要渲染');
      final TextSpan code = spans.firstWhere(
        (TextSpan s) => s.text == '码',
        orElse: () => const TextSpan(),
      );
      expect(code.style?.fontFamily, 'monospace');
    });

    testWidgets('H4–H6 与正文有层级差异（内核默认只到 H3）', (WidgetTester tester) async {
      final NoteRepository repository =
          await _createRepository(tester, 'xiaoji_h4_');
      await tester.pumpWidget(
        _buildEditor(
          repository,
          _note('h4', '#### 四级标题\n\n正文内容'),
          autoFocus: false,
        ),
      );
      await _pumpFrames(tester, frames: 12);

      final List<TextSpan> spans = collectSpans(tester);
      final TextSpan heading = spans.firstWhere(
        (TextSpan s) => s.text == '四级标题',
        orElse: () => const TextSpan(),
      );
      final TextSpan body = spans.firstWhere(
        (TextSpan s) => s.text == '正文内容',
        orElse: () => const TextSpan(),
      );
      expect(heading.style?.fontWeight, AppWeight.semibold,
          reason: 'H4 必须比正文更重，否则与正文无异');
      // 正文没有显式字重（走默认 400），所以只校验它确实不是 semibold。
      expect(body.style?.fontWeight, isNot(AppWeight.semibold));
    });

    testWidgets('代码块：字号/行高/等宽与列表摘要同源', (WidgetTester tester) async {
      final NoteRepository repository =
          await _createRepository(tester, 'xiaoji_code_style_');
      await tester.pumpWidget(
        _buildEditor(
          repository,
          _note('code_style', '```dart\nvoid main() {}\n```'),
          autoFocus: false,
        ),
      );
      await _pumpFrames(tester, frames: 12);

      final Finder code =
          find.textContaining('void main()', findRichText: true);
      expect(code, findsOneWidget);
      final RenderParagraph paragraph =
          tester.renderObject<RenderParagraph>(code);
      final TextStyle style = paragraph.text.style!;
      expect(style.fontFamily, 'monospace');
      expect(
        style.fontSize,
        closeTo(AppFontSize.summary * 0.9, 0.01),
        reason: '详情 14.4 与列表摘要 base×0.9 必须一致',
      );
      expect(style.height, 1.55, reason: '行高要与列表的 1.55 一致');
      // 底色不再逐行画在文字上：整宽圆角卡片由组件外层 Container 提供，
      // 文字本身必须干净（否则卡片里会叠出一圈毛边）。
      expect(style.backgroundColor, isNull, reason: '文字本身不能逐行铺底');
      final bool hasCard = tester
          .widgetList<CustomPaint>(
            find.ancestor(of: code, matching: find.byType(CustomPaint)),
          )
          .isNotEmpty;
      expect(hasCard, isTrue, reason: '代码块必须有整宽圆角卡片背景');
    });

    testWidgets('代码块底色与正文左缘正确', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final NoteRepository repository =
          await _createRepository(tester, 'xiaoji_code_band_');
      await tester.pumpWidget(
        _buildEditor(
          repository,
          _note('code_band', '```dart\nvoid main() {}\n```'),
          autoFocus: false,
        ),
      );
      await _pumpFrames(tester, frames: 12);

      final Finder code =
          find.textContaining('void main()', findRichText: true);
      // 文字左缘 = 页面边距 16 + 卡片内边距 12。
      expect(
        tester.getRect(code).left,
        closeTo(AppSpace.page + 12, 1),
      );
      expect(
        find
            .ancestor(of: code, matching: find.byType(CustomPaint))
            .evaluate()
            .isNotEmpty,
        isTrue,
        reason: '代码块要有整宽浅底卡片，和列表摘要一致',
      );
    });

    testWidgets('代码块与下一行的间距与列表摘要一致', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final NoteRepository repository =
          await _createRepository(tester, 'xiaoji_code_gap_');
      await tester.pumpWidget(
        _buildEditor(
          repository,
          _note('code_gap', '```dart\ncode line\n```\n代码后面的正文'),
          autoFocus: false,
        ),
      );
      await _pumpFrames(tester, frames: 12);

      final Rect code =
          tester.getRect(find.textContaining('code line', findRichText: true));
      final Rect next = tester.getRect(
        find.textContaining('代码后面的正文', findRichText: true),
      );
      // 卡片底部内边距 10 + 块间距 6（下一块不再叠加段距）= 6。
      // 列表摘要里卡片下方也只有这 6，两处肉眼一致（用户多轮反馈详情偏大）。
      expect(
        next.top - code.bottom - CodeBlockCardStyle.paddingVertical,
        closeTo(6, 0.5),
      );
    });

    testWidgets('代码块：点击可定位光标，代理测量不抛异常', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final NoteRepository repository =
          await _createRepository(tester, 'xiaoji_code_tap_');
      await tester.pumpWidget(
        _buildEditor(
          repository,
          _note('code_tap', '```dart\nvoid main() {}\n```'),
          autoFocus: false,
        ),
      );
      await _pumpFrames(tester, frames: 12);

      await tester.tap(
        find.textContaining('void main()', findRichText: true),
        warnIfMissed: false,
      );
      await _pumpFrames(tester, frames: 8);
      expect(
        tester.takeException(),
        isNull,
        reason: '点击代码块不能抛异常',
      );
      // 清掉光标闪烁等 Ticker，避免测试结束时 Timer 仍挂着。
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('代码块：点击第三行能定位到第三行，不是只能到末尾', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final NoteRepository repository =
          await _createRepository(tester, 'xiaoji_code_caret_');
      await tester.pumpWidget(
        _buildEditor(
          repository,
          _note('code_caret', '```\nline1\nline2\nline3\n```'),
        ),
      );
      await _pumpFrames(tester, frames: 12);

      final Finder code = find.textContaining('line1', findRichText: true);
      final Rect rect = tester.getRect(code);
      // 代码块现在是 3 行（解析器不再补结尾空行）：0.8 高度落在第三行。
      // 坐标若因外层内边距偏移，会落到别的行甚至文件末尾，这里要求
      // 精确落在第三行区间。
      await tester.tapAt(Offset(rect.left + 30, rect.top + rect.height * 0.8));
      await _pumpFrames(tester, frames: 6);

      final SuperEditor superEditor =
          tester.widget<SuperEditor>(find.byType(SuperEditor));
      final DocumentSelection? selection =
          superEditor.editor.composer.selection;
      expect(selection, isNotNull);
      final TextNodePosition position =
          selection!.extent.nodePosition as TextNodePosition;
      expect(
        position.offset,
        inInclusiveRange(11, 20),
        reason: '点击第三行应落在第三行附近，不能跳到开头或末尾',
      );
      // 清掉光标闪烁等 Ticker，避免测试结束时 Timer 仍挂着。
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('代码块下方的空白可以落光标，能新起一行', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final NoteRepository repository =
          await _createRepository(tester, 'xiaoji_code_below_');
      await tester.pumpWidget(
        _buildEditor(
          repository,
          _note('code_below', '```\nline1\nline2\n```'),
        ),
      );
      await _pumpFrames(tester, frames: 12);

      final Finder code = find.textContaining('line1', findRichText: true);
      final Rect rect = tester.getRect(code);
      // 代码块容器底部 padding 10 + 块间距 8：再往下是末尾的普通空段落。
      await tester.tapAt(Offset(rect.center.dx, rect.bottom + 32));
      await _pumpFrames(tester, frames: 6);

      final SuperEditor superEditor =
          tester.widget<SuperEditor>(find.byType(SuperEditor));
      final DocumentSelection? selection =
          superEditor.editor.composer.selection;
      expect(selection, isNotNull);
      final DocumentNode node =
          superEditor.editor.document.getNodeById(selection!.extent.nodeId)!;
      expect(
        node.getMetadataValue(NodeMetadata.blockType) != codeAttribution,
        isTrue,
        reason: '代码块下方应是普通段落，能继续新起一行输入',
      );
      // 清掉光标闪烁等 Ticker，避免测试结束时 Timer 仍挂着。
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  test('代码块末尾空行再回车：退出代码块，末尾变成普通段落', () {
    // ``` 内是「line1 + 空行」，光标停在末尾空行上回车。
    final MutableDocument document = deserializeXiaojiMarkdown(
      '```\nline1\n\n```',
    );
    final ParagraphNode code = document.getNodeAt(0)! as ParagraphNode;
    expect(
      code.getMetadataValue(NodeMetadata.blockType),
      codeAttribution,
    );

    final MutableDocumentComposer composer = MutableDocumentComposer();
    final Editor editor = createXiaojiEditor(
      document: document,
      composer: composer,
    );
    composer.setSelectionWithReason(
      DocumentSelection.collapsed(
        position: DocumentPosition(
          nodeId: code.id,
          nodePosition: TextNodePosition(offset: code.text.length),
        ),
      ),
      SelectionReason.userInteraction,
    );

    editor.execute(<EditRequest>[
      InsertNewlineAtCaretRequest(Editor.createNodeId()),
    ]);

    final ParagraphNode remaining = document.getNodeAt(0)! as ParagraphNode;
    expect(
      remaining.getMetadataValue(NodeMetadata.blockType),
      codeAttribution,
      reason: '上方的代码内容要保留在代码块里',
    );
    expect(remaining.text.toPlainText(), 'line1');
    final ParagraphNode below = document.getNodeAt(1)! as ParagraphNode;
    expect(
      below.getMetadataValue(NodeMetadata.blockType),
      isNot(codeAttribution),
      reason: '末尾空行要变回普通段落（退出代码块）',
    );
    expect(below.text.toPlainText(), isEmpty);
  });
}
