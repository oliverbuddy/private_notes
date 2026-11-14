import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';
import 'package:xiaoji/editor/lab/editor_request_handlers.dart';
import 'package:xiaoji/editor/lab/markdown_inline.dart';
import 'package:xiaoji/editor/lab/xiaoji_markdown.dart';

/// 手动输入 Markdown 的识别规则（用户反馈：手打标签必须实时成型）。
void main() {
  group('行内标记识别', () {
    InlineMarkdownMatch? match(String text) =>
        matchInlineMarkdown(text, text.length);

    test('加粗 **重点**', () {
      final InlineMarkdownMatch? m = match('**重点**');
      expect(m, isNotNull);
      expect(m!.kind, InlineMarkdownKind.bold);
      expect(m.contentStart, 2);
      expect(m.contentEnd, 4);
      expect(m.newContentStart, 0);
    });

    test('加粗中间带行内码（用户原文）', () {
      const String text = '脚本里**没有任何页面跳转/刷新代码**';
      final InlineMarkdownMatch? m = match(text);
      expect(m?.kind, InlineMarkdownKind.bold);
      expect(
        text.substring(m!.contentStart, m.contentEnd),
        '没有任何页面跳转/刷新代码',
      );
    });

    test('斜体 */删除线 ~~/高亮 ==/行内码 `', () {
      expect(match('*斜体*')?.kind, InlineMarkdownKind.italic);
      expect(match('~~删除~~')?.kind, InlineMarkdownKind.strikethrough);
      expect(match('==高亮==')?.kind, InlineMarkdownKind.highlight);
      expect(match('`代码`')?.kind, InlineMarkdownKind.code);
    });

    test('链接 [文字](url)', () {
      final InlineMarkdownMatch? m = match('见[官网](https://a.com)');
      expect(m, isNotNull);
      expect(m!.kind, InlineMarkdownKind.link);
      expect(m.linkUrl, 'https://a.com');
      expect(
          '见[官网](https://a.com)'.substring(m.contentStart, m.contentEnd), '官网');
    });

    test('未闭合 / 空内容 / 首尾空格不识别', () {
      expect(match('**没有闭合'), isNull);
      expect(match('****'), isNull);
      expect(match('** 空格 **'), isNull);
      expect(match('普通文本'), isNull);
      expect(match('``'), isNull);
    });

    test('连续三个星号不被当成加粗', () {
      expect(match('***'), isNull);
    });
  });

  group('行内标记落地到文档', () {
    late MutableDocument document;
    late MutableDocumentComposer composer;
    late Editor editor;

    setUp(() {
      document = MutableDocument(
        nodes: <DocumentNode>[
          ParagraphNode(id: 'p1', text: AttributedText()),
        ],
      );
      composer = MutableDocumentComposer();
      editor = createXiaojiEditor(document: document, composer: composer);
    });

    void type(String text) {
      editor.execute(<EditRequest>[
        ReplaceNodeRequest(
          existingNodeId: 'p1',
          newNode: ParagraphNode(id: 'p1', text: AttributedText(text)),
        ),
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: 'p1',
              nodePosition: TextNodePosition(offset: text.length),
            ),
          ),
          SelectionChangeType.placeCaret,
          SelectionReason.userInteraction,
        ),
      ]);
    }

    test('**重点** → 标记删除、内容加粗、光标在末尾', () {
      type('**重点**');
      final List<EditRequest>? requests =
          inlineMarkdownRequests(nodeId: 'p1', text: '**重点**', caret: 6);
      expect(requests, isNotNull);
      editor.execute(requests!);

      final ParagraphNode node = document.getNodeById('p1')! as ParagraphNode;
      expect(node.text.toPlainText(), '重点');
      expect(
        node.text.hasAttributionAt(1, attribution: boldAttribution),
        isTrue,
      );
      final TextNodePosition caret =
          composer.selection!.extent.nodePosition as TextNodePosition;
      expect(caret.offset, 2);
    });

    test('链接：文字留下、地址写进 LinkAttribution', () {
      type('见[官网](https://a.com)');
      final List<EditRequest>? requests = inlineMarkdownRequests(
        nodeId: 'p1',
        text: '见[官网](https://a.com)',
        caret: 20,
      );
      editor.execute(requests!);

      final ParagraphNode node = document.getNodeById('p1')! as ParagraphNode;
      expect(node.text.toPlainText(), '见官网');
      final Set<Attribution> at = node.text.getAllAttributionsAt(1).toSet();
      expect(
        at.whereType<LinkAttribution>().single.plainTextUri,
        'https://a.com',
      );
    });

    test('代码块里不处理（页面层已拦截，纯函数也不该误判）', () {
      // 代码内容 `**x**` 在代码块里是字面量，由页面判断 blockType 后
      // 不调用本函数；这里只验证纯函数本身不会把「未闭合」误判。
      expect(matchInlineMarkdown('a ** b', 5), isNull);
    });
  });

  group('整段扫描（粘贴后补齐）', () {
    test('多标记混排按出现顺序全部命中', () {
      const String text = '前**粗**中`码`后~~删~~与==高亮==和[链接](https://a.com)';
      final List<InlineMarkdownMatch> matches = findAllInlineMarkdown(text);
      expect(
        matches.map((InlineMarkdownMatch m) => m.kind).toList(),
        <InlineMarkdownKind>[
          InlineMarkdownKind.bold,
          InlineMarkdownKind.code,
          InlineMarkdownKind.strikethrough,
          InlineMarkdownKind.highlight,
          InlineMarkdownKind.link,
        ],
      );
    });

    test('普通算式 / 未闭合标记不误判', () {
      expect(findAllInlineMarkdown('2 * 3 * 4'), isEmpty);
      expect(findAllInlineMarkdown('a ** b'), isEmpty);
      expect(findAllInlineMarkdown('普通文本'), isEmpty);
      expect(findAllInlineMarkdown('**未闭合'), isEmpty);
      // 下划线只在两侧不是单词字符时才当语法，避免误伤变量名。
      expect(findAllInlineMarkdown('snake_case_name'), isEmpty);
      expect(findAllInlineMarkdown('my_var_name_here'), isEmpty);
    });

    test('下划线写法 __加粗__ / _斜体_', () {
      final List<InlineMarkdownMatch> matches =
          findAllInlineMarkdown('前__加粗__后_斜体_');
      expect(
        matches.map((InlineMarkdownMatch m) => m.kind).toList(),
        <InlineMarkdownKind>[
          InlineMarkdownKind.bold,
          InlineMarkdownKind.italic,
        ],
      );
    });

    test('落地：标记删除、样式生效、光标按删除量映射', () {
      final MutableDocument document = MutableDocument(
        nodes: <DocumentNode>[
          ParagraphNode(id: 'p1', text: AttributedText('前**粗**后')),
        ],
      );
      final MutableDocumentComposer composer = MutableDocumentComposer();
      final Editor editor =
          createXiaojiEditor(document: document, composer: composer);

      const String text = '前**粗**后';
      final List<EditRequest>? requests = allInlineMarkdownRequests(
        nodeId: 'p1',
        text: text,
        caret: text.length,
      );
      expect(requests, isNotNull);
      editor.execute(requests!);

      final ParagraphNode node = document.getNodeById('p1')! as ParagraphNode;
      expect(node.text.toPlainText(), '前粗后');
      expect(
        node.text.hasAttributionAt(1, attribution: boldAttribution),
        isTrue,
      );
      // 光标在末尾：原文 7 个字符，删掉 4 个标记字符 → 3。
      final TextNodePosition caret =
          composer.selection!.extent.nodePosition as TextNodePosition;
      expect(caret.offset, 3);
    });

    test('多块同帧补齐不会互相串位', () {
      final MutableDocument document = MutableDocument(
        nodes: <DocumentNode>[
          ParagraphNode(id: 'p1', text: AttributedText('A**一**B')),
          ParagraphNode(id: 'p2', text: AttributedText('C~~二~~D')),
        ],
      );
      final Editor editor = createXiaojiEditor(
        document: document,
        composer: MutableDocumentComposer(),
      );
      editor.execute(allInlineMarkdownRequests(
        nodeId: 'p1',
        text: 'A**一**B',
      )!);
      editor.execute(allInlineMarkdownRequests(
        nodeId: 'p2',
        text: 'C~~二~~D',
      )!);

      expect(
        (document.getNodeById('p1')! as ParagraphNode).text.toPlainText(),
        'A一B',
      );
      expect(
        (document.getNodeById('p2')! as ParagraphNode).text.toPlainText(),
        'C二D',
      );
    });
  });

  group('手打分割线回车生成分割线', () {
    late MutableDocument document;
    late MutableDocumentComposer composer;
    late Editor editor;

    setUp(() {
      document = MutableDocument(
        nodes: <DocumentNode>[
          ParagraphNode(id: 'p1', text: AttributedText()),
        ],
      );
      composer = MutableDocumentComposer();
      editor = createXiaojiEditor(document: document, composer: composer);
    });

    void setParagraph(String text) {
      editor.execute(<EditRequest>[
        ReplaceNodeRequest(
          existingNodeId: 'p1',
          newNode: ParagraphNode(id: 'p1', text: AttributedText(text)),
        ),
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: 'p1',
              nodePosition: TextNodePosition(offset: text.length),
            ),
          ),
          SelectionChangeType.placeCaret,
          SelectionReason.userInteraction,
        ),
      ]);
    }

    test('识别规则', () {
      expect(isHorizontalRuleLine('---'), isTrue);
      expect(isHorizontalRuleLine('***'), isTrue);
      expect(isHorizontalRuleLine('___'), isTrue);
      expect(isHorizontalRuleLine('  ---  '), isTrue);
      expect(isHorizontalRuleLine('--'), isFalse);
      expect(isHorizontalRuleLine('- 列表项'), isFalse);
      expect(isHorizontalRuleLine('正文'), isFalse);
    });

    test('智能连字符（– / —）也认', () {
      // macOS / 输入法会把 -- / --- 自动替换成 en dash / em dash。
      expect(isHorizontalRuleLine('–'), isFalse); // 只敲了两个连字符，不够长
      expect(isHorizontalRuleLine('—-'), isTrue);
      expect(isHorizontalRuleLine('—'), isTrue);
      expect(isHorizontalRuleLine('——'), isTrue);
      expect(isHorizontalRuleLine('–-'), isTrue);
      expect(isHorizontalRuleLine('— 正文'), isFalse);
    });

    test('回车后变成 HorizontalRuleNode，光标落在其后的空段落', () {
      setParagraph('---');
      editor.execute(<EditRequest>[InsertNewlineAtCaretRequest()]);

      expect(document.nodeCount, 2);
      expect(document.getNodeAt(0), isA<HorizontalRuleNode>());
      final ParagraphNode tail = document.getNodeAt(1)! as ParagraphNode;
      expect(tail.text.toPlainText(), isEmpty);
      expect(composer.selection!.extent.nodeId, tail.id);
    });

    test('普通列表行回车不受影响', () {
      setParagraph('- 一项');
      editor.execute(<EditRequest>[InsertNewlineAtCaretRequest()]);

      expect(document.getNodeAt(0), isNot(isA<HorizontalRuleNode>()));
    });
  });

  group('代码围栏回车生成代码块', () {
    late MutableDocument document;
    late MutableDocumentComposer composer;
    late Editor editor;

    setUp(() {
      document = MutableDocument(
        nodes: <DocumentNode>[
          ParagraphNode(id: 'p1', text: AttributedText()),
        ],
      );
      composer = MutableDocumentComposer();
      editor = createXiaojiEditor(document: document, composer: composer);
    });

    /// 把唯一段落改成 [text]，光标放到末尾。
    void setParagraph(String text) {
      final String nodeId = document.first.id;
      editor.execute(<EditRequest>[
        ReplaceNodeRequest(
          existingNodeId: nodeId,
          newNode: ParagraphNode(id: nodeId, text: AttributedText(text)),
        ),
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: nodeId,
              nodePosition: TextNodePosition(offset: text.length),
            ),
          ),
          SelectionChangeType.placeCaret,
          SelectionReason.userInteraction,
        ),
      ]);
    }

    test('```dart 回车 → 代码块 + 语言标记 + 空内容', () {
      setParagraph('```dart');
      final String nodeId = document.first.id;

      editor.execute(<EditRequest>[InsertNewlineAtCaretRequest()]);

      final ParagraphNode node = document.getNodeById(nodeId)! as ParagraphNode;
      expect(
        node.getMetadataValue(NodeMetadata.blockType),
        codeAttribution,
      );
      expect(node.getMetadataValue(kCodeLanguageMetadata), 'dart');
      expect(node.text.toPlainText(), isEmpty);
      final DocumentSelection? selection = composer.selection;
      expect(selection!.extent.nodeId, nodeId);
    });

    test('普通文本回车不受影响', () {
      setParagraph('普通一句');
      final String nodeId = document.first.id;

      editor.execute(<EditRequest>[InsertNewlineAtCaretRequest()]);

      expect(document.nodeCount, 2);
      expect(
        (document.getNodeById(nodeId)! as ParagraphNode)
            .getMetadataValue(NodeMetadata.blockType),
        isNot(codeAttribution),
      );
    });
  });
}
