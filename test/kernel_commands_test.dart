import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';
import 'package:xiaoji/editor/lab/kernel_commands.dart';
import 'package:xiaoji/editor/lab/xiaoji_markdown.dart';
import 'package:xiaoji/editor/markdown_toolbar.dart';

/// M2 命令映射的单元级测试：不跑 widget，直接在内存里建内核编辑器，
/// 验证 MarkdownToolbar 的命令真的落到 super_editor 的文档模型上。
///
/// 这些用例各自压着一条实测踩过的坑：
///  - 段落转标题必须保住文字（ConvertTextNodeToParagraphCommand 对
///    ParagraphNode 会无视 newMetadata，所以必须走 ChangeParagraphBlockType）；
///  - 列表/引用转换不许清文字（M1 传空 AttributedText 是已知缺陷）；
///  - 插代码块后光标必须落在代码块节点里，且不能产生悬挂选区。
void main() {
  late MutableDocument document;
  late MutableDocumentComposer composer;
  late Editor editor;
  late CommonEditorOperations ops;
  late KernelCommands commands;

  setUp(() {
    document = deserializeXiaojiMarkdown('');
    composer = MutableDocumentComposer();
    editor = createDefaultDocumentEditor(
      document: document,
      composer: composer,
      isHistoryEnabled: true,
    );
    ops = CommonEditorOperations(
      document: document,
      editor: editor,
      composer: composer,
      documentLayoutResolver: () =>
          throw UnimplementedError('命令映射不依赖布局解析器'),
    );
    commands = KernelCommands(
      editor: editor,
      document: document,
      composer: composer,
      ops: ops,
    );
  });

  /// 把光标折叠加到第 [nodeIndex] 个节点、偏移 [offset] 处。
  void placeCaretAt(int nodeIndex, {int offset = 0}) {
    final node = document.getNodeAt(nodeIndex)!;
    composer.setSelectionWithReason(
      DocumentSelection.collapsed(
        position: DocumentPosition(
          nodeId: node.id,
          nodePosition: TextNodePosition(offset: offset),
        ),
      ),
    );
  }

  test('段落转 H2：文字保留，块类型生效', () {
    editor.execute(<EditRequest>[
      InsertNodeAtIndexRequest(
        nodeIndex: 0,
        newNode: ParagraphNode(
          id: Editor.createNodeId(),
          text: AttributedText('第一段文字'),
        ),
      ),
    ]);
    placeCaretAt(0, offset: 3);

    commands.handleCommand(MarkdownCommand.h2);

    final node = document.getNodeAt(0)! as ParagraphNode;
    expect(node.text.toPlainText(), '第一段文字', reason: '转标题不许动文字');
    expect(
      node.getMetadataValue(NodeMetadata.blockType),
      header2Attribution,
      reason: 'ConvertTextNodeToParagraphCommand 对 ParagraphNode 会无视 '
          'newMetadata，必须走 ChangeParagraphBlockTypeRequest 才生效',
    );
    expect(commands.computeActiveCommands(), contains(MarkdownCommand.h2));
  });

  test('光标在标题行时插附件：另起段落，标题文字不被吞掉', () {
    editor.execute(<EditRequest>[
      InsertNodeAtIndexRequest(
        nodeIndex: 0,
        newNode: ParagraphNode(
          id: Editor.createNodeId(),
          text: AttributedText('购物清单'),
          metadata: const <String, dynamic>{
            NodeMetadata.blockType: header2Attribution,
          },
        ),
      ),
    ]);
    placeCaretAt(0, offset: 4);

    commands.insertAttachment('a.pdf', 'assets/n1/a.pdf');

    final heading = document.getNodeAt(0)! as ParagraphNode;
    expect(heading.text.toPlainText(), '购物清单', reason: '标题文字必须保留');
    expect(
      heading.getMetadataValue(NodeMetadata.blockType),
      header2Attribution,
      reason: '标题不能被附件改写',
    );
    final paragraph = document.getNodeAt(1)! as ParagraphNode;
    expect(paragraph.text.toPlainText(), 'a.pdf');
    expect(
      paragraph.text.spans
          .getAllAttributionsAt(0)
          .whereType<LinkAttribution>()
          .single
          .plainTextUri,
      'assets/n1/a.pdf',
    );
  });

  test('段落转待办再转回来：文字全程保留', () {
    editor.execute(<EditRequest>[
      InsertNodeAtIndexRequest(
        nodeIndex: 0,
        newNode: ParagraphNode(
          id: Editor.createNodeId(),
          text: AttributedText('买牛奶'),
        ),
      ),
    ]);
    placeCaretAt(0, offset: 0);

    commands.handleCommand(MarkdownCommand.todo);
    var node = document.getNodeAt(0)!;
    expect(node, isA<TaskNode>());
    expect((node as TaskNode).text.toPlainText(), '买牛奶');
    expect(commands.computeActiveCommands(), contains(MarkdownCommand.todo));

    commands.handleCommand(MarkdownCommand.todo);
    node = document.getNodeAt(0)!;
    expect(node, isA<ParagraphNode>(), reason: '再点一次待办 = 退回正文');
    expect((node as ParagraphNode).text.toPlainText(), '买牛奶');
  });

  test('段落转无序列表：整行文字保留（M1 清空缺陷回归）', () {
    editor.execute(<EditRequest>[
      InsertNodeAtIndexRequest(
        nodeIndex: 0,
        newNode: ParagraphNode(
          id: Editor.createNodeId(),
          text: AttributedText('购物清单第一项'),
        ),
      ),
    ]);
    placeCaretAt(0, offset: 2);

    commands.handleCommand(MarkdownCommand.bullet);

    final node = document.getNodeAt(0)! as ListItemNode;
    expect(node.type, ListItemType.unordered);
    expect(node.text.toPlainText(), '购物清单第一项');
  });

  test('段落转引用再退回：文字保留，激活态同步', () {
    editor.execute(<EditRequest>[
      InsertNodeAtIndexRequest(
        nodeIndex: 0,
        newNode: ParagraphNode(
          id: Editor.createNodeId(),
          text: AttributedText('一段引用的话'),
        ),
      ),
    ]);
    placeCaretAt(0, offset: 0);

    commands.handleCommand(MarkdownCommand.quote);
    var node = document.getNodeAt(0)! as ParagraphNode;
    expect(node.getMetadataValue(NodeMetadata.blockType),
        blockquoteAttribution);
    expect(node.text.toPlainText(), '一段引用的话');
    expect(commands.computeActiveCommands(), contains(MarkdownCommand.quote));

    commands.handleCommand(MarkdownCommand.quote);
    node = document.getNodeAt(0)! as ParagraphNode;
    expect(node.getMetadataValue(NodeMetadata.blockType),
        isNot(blockquoteAttribution));
    expect(node.text.toPlainText(), '一段引用的话');
  });

  test('有内容的段落插代码块：光标落进代码块，无悬挂选区', () {
    editor.execute(<EditRequest>[
      InsertNodeAtIndexRequest(
        nodeIndex: 0,
        newNode: ParagraphNode(
          id: Editor.createNodeId(),
          text: AttributedText('上面一行'),
        ),
      ),
    ]);
    placeCaretAt(0, offset: 4);

    commands.handleCommand(MarkdownCommand.codeBlock);

    expect(document.nodeCount, 4,
        reason: '光标在段落末尾：内核会在代码块后再垫一个空段落接住光标'
            '（4 = 原段落 + 代码块 + 垫的空段落 + 解析空文档自带的空段落）');
    final codeNode = document.getNodeAt(1)! as ParagraphNode;
    expect(codeNode.getMetadataValue(NodeMetadata.blockType), codeAttribution);
    // 选区必须指向真实存在的节点，否则后续渲染直接崩。
    final selection = composer.selection!;
    expect(document.getNodeById(selection.extent.nodeId), same(codeNode));
    expect(
      (selection.extent.nodePosition as TextNodePosition).offset,
      0,
      reason: '光标进代码块开头，下一步就是写代码',
    );
  });

  test('分隔线插在光标处，原文不动', () {
    editor.execute(<EditRequest>[
      InsertNodeAtIndexRequest(
        nodeIndex: 0,
        newNode: ParagraphNode(
          id: Editor.createNodeId(),
          text: AttributedText('正文'),
        ),
      ),
    ]);
    placeCaretAt(0, offset: 2);

    commands.handleCommand(MarkdownCommand.divider);

    expect(document.getNodeAt(1)!, isA<HorizontalRuleNode>());
    expect(
      (document.getNodeAt(0)! as ParagraphNode).text.toPlainText(),
      '正文',
    );
  });

  test('展开选区上行内样式激活：覆盖整段选区才点亮', () {
    editor.execute(<EditRequest>[
      InsertNodeAtIndexRequest(
        nodeIndex: 0,
        newNode: ParagraphNode(
          id: Editor.createNodeId(),
          text: AttributedText('普通加粗字普通'),
        ),
      ),
    ]);
    final node = document.getNodeAt(0)! as ParagraphNode;
    // 给「加粗字」三个字（下标 2..4）挂粗体。
    editor.execute(<EditRequest>[
      AddTextAttributionsRequest(
        documentRange: DocumentRange(
          start: DocumentPosition(
            nodeId: node.id,
            nodePosition: const TextNodePosition(offset: 2),
          ),
          end: DocumentPosition(
            nodeId: node.id,
            nodePosition: const TextNodePosition(offset: 4),
          ),
        ),
        attributions: <Attribution>{boldAttribution},
      ),
    ]);

    // 选区完全落在粗体区间内 → 点亮（选区 2..4）。
    composer.setSelectionWithReason(
      DocumentSelection(
        base: DocumentPosition(
          nodeId: node.id,
          nodePosition: const TextNodePosition(offset: 2),
        ),
        extent: DocumentPosition(
          nodeId: node.id,
          nodePosition: const TextNodePosition(offset: 4),
        ),
      ),
    );
    expect(commands.computeActiveCommands(), contains(MarkdownCommand.bold));

    // 选区跨出粗体左边界 → 不亮（选区 1..3，起点不在粗体上）。
    composer.setSelectionWithReason(
      DocumentSelection(
        base: DocumentPosition(
          nodeId: node.id,
          nodePosition: const TextNodePosition(offset: 1),
        ),
        extent: DocumentPosition(
          nodeId: node.id,
          nodePosition: const TextNodePosition(offset: 3),
        ),
      ),
    );
    expect(
      commands.computeActiveCommands(),
      isNot(contains(MarkdownCommand.bold)),
    );
  });

  test('选区内行内样式命令真的落到 spans（Aa 面板第二行）', () {
    editor.execute(<EditRequest>[
      InsertNodeAtIndexRequest(
        nodeIndex: 0,
        newNode: ParagraphNode(
          id: Editor.createNodeId(),
          text: AttributedText('加粗斜体删除线行内码高亮'),
        ),
      ),
    ]);
    final node = document.getNodeAt(0)! as ParagraphNode;

    void select(int start, int end) {
      composer.setSelectionWithReason(
        DocumentSelection(
          base: DocumentPosition(
            nodeId: node.id,
            nodePosition: TextNodePosition(offset: start),
          ),
          extent: DocumentPosition(
            nodeId: node.id,
            nodePosition: TextNodePosition(offset: end),
          ),
        ),
      );
    }

    const cases = <(MarkdownCommand, Attribution, int, int)>[
      (MarkdownCommand.bold, boldAttribution, 0, 2),
      (MarkdownCommand.italic, italicsAttribution, 2, 4),
      (MarkdownCommand.strike, strikethroughAttribution, 4, 7),
      (MarkdownCommand.code, codeAttribution, 7, 10),
      (MarkdownCommand.highlight, highlightAttribution, 10, 12),
    ];
    for (final (command, attribution, start, end) in cases) {
      select(start, end);
      commands.handleCommand(command);
      final spans = document.getNodeAt(0)! as ParagraphNode;
      expect(
        spans.text.spans.getAttributionSpansInRange(
          attributionFilter: (Attribution a) => a == attribution,
          start: start,
          end: end - 1,
        ),
        hasLength(1),
        reason: '$command 必须作用在选区上（否则 Aa 面板按钮等于无效）',
      );
    }
  });

  test('折叠光标下行内样式写入输入态，再点一次可取消', () {
    editor.execute(<EditRequest>[
      InsertNodeAtIndexRequest(
        nodeIndex: 0,
        newNode: ParagraphNode(
          id: Editor.createNodeId(),
          text: AttributedText('光标处'),
        ),
      ),
    ]);

    const cases = <(MarkdownCommand, Attribution)>[
      (MarkdownCommand.bold, boldAttribution),
      (MarkdownCommand.italic, italicsAttribution),
      (MarkdownCommand.strike, strikethroughAttribution),
      (MarkdownCommand.code, codeAttribution),
      (MarkdownCommand.highlight, highlightAttribution),
    ];
    for (final (command, attribution) in cases) {
      // 每个用例都从一个干净的输入态开始。
      composer.preferences.clearStyles();
      placeCaretAt(0, offset: 1);

      commands.handleCommand(command);
      expect(
        composer.preferences.currentAttributions,
        contains(attribution),
        reason: '$command 在折叠光标下必须写入输入态，否则点了没反应',
      );
      expect(
        commands.computeActiveCommands(),
        contains(command),
        reason: '$command 写入输入态后 Aa 按钮要能点亮',
      );

      commands.handleCommand(command);
      expect(
        composer.preferences.currentAttributions,
        isNot(contains(attribution)),
        reason: '$command 再点一次必须取消',
      );
    }
  });
}
