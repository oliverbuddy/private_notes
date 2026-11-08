import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';
import 'package:xiaoji/editor/lab/editor_request_handlers.dart';
import 'package:xiaoji/editor/lab/markdown_paste.dart';
import 'package:xiaoji/editor/lab/xiaoji_markdown.dart';

class _FakeReader extends ClipboardReader {
  const _FakeReader(this.content);

  final ClipboardContent content;

  @override
  Future<ClipboardContent> read() async => content;
}

List<DocumentNode> _nodes(Document document) {
  return <DocumentNode>[
    for (int i = 0; i < document.nodeCount; i++) document.getNodeAt(i)!,
  ];
}

void main() {
  group('looksLikeMarkdown', () {
    test('多处块级标记按 Markdown 处理', () {
      expect(looksLikeMarkdown('# 标题\n- 一\n- 二'), isTrue);
      expect(looksLikeMarkdown('1. 第一\n2. 第二'), isTrue);
      expect(looksLikeMarkdown('> 引用\n\n```\ncode\n```'), isTrue);
    });

    test('行内标记按 Markdown 处理', () {
      expect(looksLikeMarkdown('看这个 [链接](https://a.com)'), isTrue);
      expect(looksLikeMarkdown('这里有 **加粗**'), isTrue);
      expect(looksLikeMarkdown('行内 `code` 片段'), isTrue);
    });

    test('普通聊天文本保持纯文本', () {
      expect(looksLikeMarkdown('今天天气不错'), isFalse);
      expect(looksLikeMarkdown('- 只有一行短横线'), isFalse);
      expect(looksLikeMarkdown('1.5 倍速'), isFalse);
    });
  });

  group('markdownFromClipboard', () {
    test('HTML 优先于纯文本', () {
      final String? md = markdownFromClipboard(
        text: 'raw',
        html: '<h1>标题</h1><p>正文</p>',
      );
      expect(md, contains('# 标题'));
      expect(md, contains('正文'));
    });

    test('无 HTML 且不像 Markdown 时返回 null', () {
      expect(markdownFromClipboard(text: '普通一句话'), isNull);
    });

    test('富文本项目符号归一化成列表', () {
      final String? md = markdownFromClipboard(
        text: '购物清单\n• 苹果\n• 香蕉',
      );
      expect(md, isNotNull);
      expect(md, contains('- 苹果'));
      expect(md, contains('- 香蕉'));
    });
  });

  group('normalizePlainBullets', () {
    test('两行以上才转换', () {
      expect(normalizePlainBullets('• 一\n· 二'), '- 一\n- 二');
      expect(normalizePlainBullets('• 只有一行'), isNull);
    });
  });

  group('shouldTreatImeInsertAsPaste', () {
    test('快照过期时，结构明确的 Markdown 仍然拦截', () {
      expect(
        shouldTreatImeInsertAsPaste(
          '# 标题\n\n正文一段足够长的内容用来判断',
          clipboardText: '上一次复制的完全不同的内容，长度也够',
          clipboardHtml: null,
        ),
        isTrue,
      );
    });

    test('快照过期时，多行纯文本也按粘贴处理', () {
      expect(
        shouldTreatImeInsertAsPaste(
          '第一段普通文字内容再长一点\n第二段普通文字内容再长一点',
          clipboardText: '旧内容',
        ),
        isTrue,
      );
    });

    test('短文本、单行普通输入不拦截', () {
      expect(shouldTreatImeInsertAsPaste('你好'), isFalse);
      expect(
        shouldTreatImeInsertAsPaste('今天天气不错，我们出去走走吧'),
        isFalse,
      );
    });

    test('与快照一致且有 HTML 时拦截', () {
      const String text = '一段被复制过的正文内容，长度肯定超过二十个字符阈值';
      expect(
        shouldTreatImeInsertAsPaste(
          text,
          clipboardText: text,
          clipboardHtml: '<p>$text</p>',
        ),
        isTrue,
      );
    });
  });

  group('clipboardTextsMatch', () {
    test('忽略空白与换行差异', () {
      expect(clipboardTextsMatch('a b\nc', 'ab c'), isTrue);
      expect(clipboardTextsMatch('abc', 'xyz'), isFalse);
    });
  });

  group('MarkdownPaster', () {
    late MutableDocument document;
    late MutableDocumentComposer composer;
    late Editor editor;
    late CommonEditorOperations ops;

    setUp(() {
      document = deserializeXiaojiMarkdown('intro');
      composer = MutableDocumentComposer();
      editor = createXiaojiEditor(document: document, composer: composer);
      ops = CommonEditorOperations(
        document: document,
        editor: editor,
        composer: composer,
        documentLayoutResolver: () =>
            throw UnimplementedError('粘贴测试不依赖布局解析器'),
      );
    });

    void placeCaretAt(int nodeIndex, {int offset = 0}) {
      final DocumentNode node = document.getNodeAt(nodeIndex)!;
      editor.execute(<EditRequest>[
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: node.id,
              nodePosition: TextNodePosition(offset: offset),
            ),
          ),
          SelectionChangeType.placeCaret,
          SelectionReason.userInteraction,
        ),
      ]);
    }

    test('单段行内 Markdown 并入当前段落', () async {
      placeCaretAt(0, offset: 5);
      final bool handled = await MarkdownPaster(
        editor: editor,
        document: document,
        composer: composer,
        ops: ops,
        reader: const _FakeReader(ClipboardContent(text: '**X**')),
      ).paste();

      expect(handled, isTrue);
      final DocumentNode node = _nodes(document).first;
      expect((node as ParagraphNode).text.toPlainText(), 'introX');
      expect(
        node.text.hasAttributionAt(5, attribution: boldAttribution),
        isTrue,
      );
    });

    test('多块 Markdown 插到光标段落后，光标落在最后一块末尾', () async {
      placeCaretAt(0, offset: 5);
      final bool handled = await MarkdownPaster(
        editor: editor,
        document: document,
        composer: composer,
        ops: ops,
        reader: const _FakeReader(
          ClipboardContent(text: '# 标题\n\n- 一\n- 二'),
        ),
      ).paste();

      expect(handled, isTrue);
      final List<DocumentNode> nodes = _nodes(document);
      expect(nodes.length, greaterThanOrEqualTo(4));

      final ParagraphNode intro = nodes[0] as ParagraphNode;
      expect(intro.text.toPlainText(), 'intro');

      final ParagraphNode heading = nodes[1] as ParagraphNode;
      expect(heading.text.toPlainText(), '标题');
      expect(heading.metadata[NodeMetadata.blockType], header1Attribution);

      expect((nodes[2] as ListItemNode).text.toPlainText(), '一');
      expect((nodes[3] as ListItemNode).text.toPlainText(), '二');

      final DocumentSelection selection = composer.selection!;
      expect(selection.extent.nodeId, nodes[3].id);
      expect(selection.extent.nodePosition, const TextNodePosition(offset: 1));
    });

    test('空段落粘贴：用第一个块替换空段落，不留空白', () async {
      document = deserializeXiaojiMarkdown('');
      composer = MutableDocumentComposer();
      editor = createXiaojiEditor(document: document, composer: composer);
      ops = CommonEditorOperations(
        document: document,
        editor: editor,
        composer: composer,
        documentLayoutResolver: () =>
            throw UnimplementedError('粘贴测试不依赖布局解析器'),
      );
      placeCaretAt(0);

      final bool handled = await MarkdownPaster(
        editor: editor,
        document: document,
        composer: composer,
        ops: ops,
        reader: const _FakeReader(
          ClipboardContent(text: '## 小节\n\n正文'),
        ),
      ).paste();

      expect(handled, isTrue);
      final List<DocumentNode> nodes = _nodes(document);
      final ParagraphNode heading = nodes.first as ParagraphNode;
      expect(heading.text.toPlainText(), '小节');
      expect(heading.metadata[NodeMetadata.blockType], header2Attribution);
      expect((nodes[1] as ParagraphNode).text.toPlainText(), '正文');
      expect(nodes.length, 2);
    });

    test('光标在段落中间粘贴多块：前后文顺序保持', () async {
      document = deserializeXiaojiMarkdown('hello world');
      composer = MutableDocumentComposer();
      editor = createXiaojiEditor(document: document, composer: composer);
      ops = CommonEditorOperations(
        document: document,
        editor: editor,
        composer: composer,
        documentLayoutResolver: () =>
            throw UnimplementedError('粘贴测试不依赖布局解析器'),
      );
      placeCaretAt(0, offset: 5);

      final bool handled = await MarkdownPaster(
        editor: editor,
        document: document,
        composer: composer,
        ops: ops,
        reader: const _FakeReader(
          ClipboardContent(text: '# H\n\nX'),
        ),
      ).paste();

      expect(handled, isTrue);
      final List<DocumentNode> nodes = _nodes(document);
      expect((nodes[0] as ParagraphNode).text.toPlainText(), 'hello');
      expect((nodes[1] as ParagraphNode).text.toPlainText(), 'H');
      expect((nodes[2] as ParagraphNode).text.toPlainText(), 'X');
      expect((nodes[3] as ParagraphNode).text.toPlainText(), ' world');
      final DocumentSelection selection = composer.selection!;
      expect(selection.extent.nodeId, nodes[3].id);
      expect(selection.extent.nodePosition, const TextNodePosition(offset: 0));
    });

    test('HTML 富文本按 Markdown 解析', () async {
      placeCaretAt(0, offset: 5);
      final bool handled = await MarkdownPaster(
        editor: editor,
        document: document,
        composer: composer,
        ops: ops,
        reader: const _FakeReader(
          ClipboardContent(
            text: 'world bold',
            html: '<p>world <strong>bold</strong></p>',
          ),
        ),
      ).paste();

      expect(handled, isTrue);
      final ParagraphNode node = _nodes(document).first as ParagraphNode;
      expect(node.text.toPlainText(), 'introworld bold');
      expect(
        node.text.hasAttributionAt(11, attribution: boldAttribution),
        isTrue,
      );
    });
  });

  group('表格识别', () {
    test('GFM 表格按 Markdown 处理', () {
      expect(
        looksLikeMarkdown('| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |'),
        isTrue,
      );
    });

    test('只有管道行不算表格', () {
      expect(looksLikeMarkdown('a | b'), isFalse);
      expect(looksLikeMarkdown('| 只有一行 |'), isFalse);
    });

    test('制表符分隔文本转表格', () {
      final String? md = tabSeparatedToMarkdown('名称\t数量\n苹果\t3\n香蕉\t5');
      expect(
        md,
        '| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |\n| 香蕉 | 5 |',
      );
    });

    test('列数不一致不转表格', () {
      expect(tabSeparatedToMarkdown('a\tb\nc\td\te'), isNull);
      expect(tabSeparatedToMarkdown('单列\n文本'), isNull);
    });
  });
}
