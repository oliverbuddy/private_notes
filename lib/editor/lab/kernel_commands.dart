import 'package:flutter/services.dart' show TextAffinity;
import 'package:super_editor/super_editor.dart';

import '../markdown_toolbar.dart';
import 'xiaoji_markdown.dart';

/// super_editor 内核的命令映射层（M2）。
///
/// 把 [MarkdownToolbar] 的 [MarkdownCommand] 翻译成内核 EditRequest。独立成
/// 纯 Dart 类（不依赖 widget 树）是为了能在无渲染的单元测试里跑真编辑器：
/// 工具栏回调写错一个 nodeId 拼写，测试就能拦住，而不是等真机点出来。
///
/// 踩坑记录（0.3.0-dev.52 实测源码依据）：
///  - `CommonEditorOperations.convertToParagraph(newMetadata: …)` 对
///    **ParagraphNode** 会无视 newMetadata、强制把 blockType 重置成
///    paragraphAttribution（见 ConvertTextNodeToParagraphCommand：ParagraphNode
///    分支写死 `blockType: paragraphAttribution`）。所以「段落 → 标题」不能走
///    它，必须用 `ChangeParagraphBlockTypeRequest`。
///  - `CommonEditorOperations` 构造时的 documentLayoutResolver 若抛
///    UnimplementedError，只有「移动光标到视觉位置」类操作会炸；本类用到的
///    请求全部是纯文档操作，不经过布局解析器（逐个核对过源码）。
class KernelCommands {
  KernelCommands({
    required this.editor,
    required this.document,
    required this.composer,
    required this.ops,
  });

  final Editor editor;
  final MutableDocument document;
  final MutableDocumentComposer composer;

  /// 复用页面已构造好的 CommonEditorOperations：列表/引用/行内样式等
  /// 「替换节点」类操作它封装得更完整（保留选区、可撤销）。
  final CommonEditorOperations ops;

  /// 工具条命令总入口。
  void handleCommand(MarkdownCommand command) {
    switch (command) {
      case MarkdownCommand.paragraph:
        _convertToParagraph();
        break;
      case MarkdownCommand.h1:
        _convertToHeader(1);
        break;
      case MarkdownCommand.h2:
        _convertToHeader(2);
        break;
      case MarkdownCommand.h3:
        _convertToHeader(3);
        break;
      case MarkdownCommand.todo:
        _toggleTask();
        break;
      case MarkdownCommand.bullet:
        _convertToListItem(ListItemType.unordered);
        break;
      case MarkdownCommand.ordered:
        _convertToListItem(ListItemType.ordered);
        break;
      case MarkdownCommand.quote:
        _toggleQuote();
        break;
      case MarkdownCommand.bold:
        _toggleInline(<Attribution>{boldAttribution});
        break;
      case MarkdownCommand.italic:
        _toggleInline(<Attribution>{italicsAttribution});
        break;
      case MarkdownCommand.strike:
        _toggleInline(<Attribution>{strikethroughAttribution});
        break;
      case MarkdownCommand.code:
        _toggleInline(<Attribution>{codeAttribution});
        break;
      case MarkdownCommand.highlight:
        _toggleInline(<Attribution>{highlightAttribution});
        break;
      case MarkdownCommand.link:
        _applyLink();
        break;
      case MarkdownCommand.codeBlock:
        _insertCodeBlock();
        break;
      case MarkdownCommand.divider:
        _insertDivider();
        break;
      case MarkdownCommand.indent:
        _indent(true);
        break;
      case MarkdownCommand.outdent:
        _indent(false);
        break;
    }
  }

  /// 行内样式切换。
  ///
  /// 折叠光标（没选中文字）时 [CommonEditorOperations.toggleAttributionsOnSelection]
  /// 会直接返回 false —— 内核只对非空选区生效。之前用户在只有光标时点
  /// 「加粗 / 斜体 / 删除线 / 行内码 / 高亮」毫无反应，就是这里漏了分支。
  /// 对齐官方移动工具栏的做法：折叠光标写进 composer 的输入态，下一次
  /// 输入的字符自动带上该样式。
  void _toggleInline(Set<Attribution> attributions) {
    final selection = composer.selection;
    if (selection == null) {
      return;
    }
    if (selection.isCollapsed) {
      ops.toggleComposerAttributions(attributions);
    } else {
      ops.toggleAttributionsOnSelection(attributions);
    }
  }

  /// 缩进/减少缩进。列表项走 ops；待办行内核有专用请求
  /// （IndentTaskRequest/UnIndentTaskRequest，M2 时只认 ListItemNode 是漏配）。
  void _indent(bool deeper) {
    final node = _selectedNode;
    if (node == null) {
      return;
    }
    if (node is TaskNode) {
      editor.execute(<EditRequest>[
        deeper
            ? IndentTaskRequest(node.id)
            : UnIndentTaskRequest(node.id),
      ]);
      return;
    }
    if (deeper) {
      ops.indentListItem();
    } else {
      ops.unindentListItem();
    }
  }

  /// 插入 `[文字](url)` 并把选区选住 url 段 —— 早期版本 _applyLink 同款
  /// 交互：插入后直接打字就是在写链接地址。
  void _applyLink() {
    final node = _selectedNode;
    if (node == null) {
      return;
    }
    final selection = composer.selection;
    if (selection == null) {
      return;
    }
    final plain = node.text.toPlainText();
    int offsetOf(DocumentPosition position) {
      final nodePosition = position.nodePosition;
      return nodePosition is TextNodePosition ? nodePosition.offset : 0;
    }

    final base = offsetOf(selection.base);
    final extent = offsetOf(selection.extent);
    final start = base < extent ? base : extent;
    final end = base < extent ? extent : base;
    final selected = start < end ? plain.substring(start, end) : '';
    final label = selected.isEmpty ? '文字' : selected;
    final inserted = '[$label](url)';

    // 展开选区先删（与 ops.insertPlainText 同语义），再在光标处插入。
    if (!selection.isCollapsed) {
      editor.execute(<EditRequest>[
        const DeleteSelectionRequest(TextAffinity.downstream),
      ]);
    }
    editor.execute(<EditRequest>[
      InsertPlainTextAtCaretRequest(inserted),
    ]);
    final urlStart = start + 1 + label.length + 2;
    editor.execute(<EditRequest>[
      ChangeSelectionRequest(
        DocumentSelection(
          base: DocumentPosition(
            nodeId: node.id,
            nodePosition: TextNodePosition(offset: urlStart),
          ),
          extent: DocumentPosition(
            nodeId: node.id,
            nodePosition: TextNodePosition(offset: urlStart + 3),
          ),
        ),
        SelectionChangeType.expandSelection,
        SelectionReason.userInteraction,
      ),
    ]);
  }

  /// 插入文件附件：带 LinkAttribution 的文件名文本。
  ///
  /// 旧实现插的是字面量 `[名](assets/…)`；新内核不会把运行期文本
  /// 重新解析成链接，结果页面上是一串源码、也点不动。这里直接构造
  /// 带链接属性的 AttributedText，显示与序列化都正确。
  void insertAttachment(String name, String url) {
    final selection = composer.selection;
    if (selection == null) {
      return;
    }
    final AttributedText text = _attachmentText(name, url);
    if (!selection.isCollapsed) {
      editor.execute(<EditRequest>[
        const DeleteSelectionRequest(TextAffinity.downstream),
      ]);
    }
    // 标题 / 引用 / 代码块里直接插链接，会把「整块」变成一条链接文本
    // （实测：`## ` 标题整行被附件接管，标题文字消失、序列化后变成
    // `## [文件](assets/…)`）。这类块不接收附件：另起一个普通段落，
    // 插在它后面。
    final DocumentNode? node = document.getNodeById(selection.extent.nodeId);
    if (node != null && !_acceptsInlineAttachment(node)) {
      _insertParagraphAfter(node, text);
      return;
    }
    editor.execute(<EditRequest>[
      InsertStyledTextAtCaretRequest(text),
    ]);
  }

  /// 附件文本：文件名 + 覆盖全文的本地链接。
  AttributedText _attachmentText(String name, String url) {
    final AttributedText text = AttributedText(name);
    if (name.isNotEmpty) {
      text.addAttribution(
        LinkAttribution(url),
        SpanRange(0, name.length - 1),
      );
    }
    return text;
  }

  /// 能否把附件直接插进这个节点。
  ///
  /// 只有普通段落可以；标题/引用/代码块的块类型语义会被整行链接破坏，
  /// 列表项/任务项同理（附件会变成列表项的一部分）。
  bool _acceptsInlineAttachment(DocumentNode node) {
    if (node is! ParagraphNode) {
      return false;
    }
    final Object? blockType =
        node.getMetadataValue(NodeMetadata.blockType);
    return blockType == null || blockType == paragraphAttribution;
  }

  /// 在 [node] 后面插入一个只含附件的新段落，并把光标落到段尾。
  void _insertParagraphAfter(DocumentNode node, AttributedText text) {
    final int index = document.getNodeIndexById(node.id);
    final ParagraphNode paragraph = ParagraphNode(
      id: Editor.createNodeId(),
      text: text,
    );
    editor.execute(<EditRequest>[
      InsertNodeAtIndexRequest(nodeIndex: index + 1, newNode: paragraph),
      ChangeSelectionRequest(
        DocumentSelection.collapsed(
          position: DocumentPosition(
            nodeId: paragraph.id,
            nodePosition: TextNodePosition(offset: text.length),
          ),
        ),
        SelectionChangeType.placeCaret,
        SelectionReason.userInteraction,
      ),
    ]);
  }

  // ---------------------------------------------------------------------------
  // 块级转换
  // ---------------------------------------------------------------------------

  /// 当前选区 extent 所在节点；无选区或非文本节点返回 null。
  ///
  /// 用 extent 而不是 base：单节点选区两者一致；跨节点选区一律拒绝操作
  /// （与 CommonEditorOperations 的防御一致）。
  TextNode? get _selectedNode {
    final selection = composer.selection;
    if (selection == null) {
      return null;
    }
    if (selection.base.nodeId != selection.extent.nodeId) {
      return null;
    }
    final node = document.getNodeById(selection.extent.nodeId);
    return node is TextNode ? node : null;
  }

  /// 转回正文。TaskNode / ListItemNode / 带标题引用的段落都能归位。
  void _convertToParagraph() {
    final node = _selectedNode;
    if (node == null) {
      return;
    }
    if (node is TaskNode) {
      // TaskNode 转 Paragraph 有专用请求（会剥掉 checkbox 语义）。
      editor.execute(<EditRequest>[
        ConvertTaskToParagraphRequest(nodeId: node.id),
      ]);
      return;
    }
    ops.convertToParagraph();
  }

  /// 设为 N 级标题。段落走 [ChangeParagraphBlockTypeRequest]（见类头踩坑
  /// 记录）；列表/待办先转段落再挂标题元数据。
  void _convertToHeader(int level) {
    final node = _selectedNode;
    if (node == null) {
      return;
    }
    final blockType = switch (level) {
      1 => header1Attribution,
      2 => header2Attribution,
      _ => header3Attribution,
    };
    if (node is ParagraphNode) {
      editor.execute(<EditRequest>[
        ChangeParagraphBlockTypeRequest(nodeId: node.id, blockType: blockType),
      ]);
      return;
    }
    editor.execute(<EditRequest>[
      ConvertTextNodeToParagraphRequest(
        nodeId: node.id,
        newMetadata: <String, dynamic>{NodeMetadata.blockType: blockType},
      ),
    ]);
  }

  /// 待办切换：已是待办 → 正文；否则 → 待办。文本全程保留
  /// （两个请求都按原 id 重建节点并搬运 text）。
  void _toggleTask() {
    final node = _selectedNode;
    if (node == null) {
      return;
    }
    if (node is TaskNode) {
      editor.execute(<EditRequest>[
        ConvertTaskToParagraphRequest(nodeId: node.id),
      ]);
      return;
    }
    if (node is ListItemNode) {
      // 列表行点「待办」：先归位段落再挂待办语义（undo 分两步，可接受）。
      // 之前对列表行静默 no-op，是「部分按钮没反应」的另一处。
      editor.execute(<EditRequest>[
        ConvertTextNodeToParagraphRequest(nodeId: node.id),
        ConvertParagraphToTaskRequest(nodeId: node.id),
      ]);
      return;
    }
    if (node is ParagraphNode) {
      editor.execute(<EditRequest>[
        ConvertParagraphToTaskRequest(nodeId: node.id),
      ]);
    }
  }

  /// 列表切换：已是同类型 → 正文（旧工具条的「再点一次取消」语义）；
  /// 否则转换并**保留节点原文**。M1 传空 AttributedText 会清掉整行文字，
  /// 是已知缺陷，M2 修掉。
  void _convertToListItem(ListItemType type) {
    final node = _selectedNode;
    if (node == null) {
      return;
    }
    if (node is ListItemNode && node.type == type) {
      _convertToParagraph();
      return;
    }
    ops.convertToListItem(type, node.text);
  }

  /// 引用切换：已是引用 → 正文；否则转换并保留原文。
  void _toggleQuote() {
    final node = _selectedNode;
    if (node == null) {
      return;
    }
    if (node is ParagraphNode &&
        node.getMetadataValue(NodeMetadata.blockType) ==
            blockquoteAttribution) {
      _convertToParagraph();
      return;
    }
    ops.convertToBlockquote(node.text);
  }

  /// 插入代码块段落，并把光标放进代码块里 —— 下一步就是写代码。
  ///
  ///  - 空段落：原地变代码块（不凭空多一行，与旧版 _insertCodeBlock 的
  ///    「围栏独占一行」精神一致）；
  ///  - 有内容段落：代码块插在当前段落之后，光标移进代码块开头。
  void _insertCodeBlock() {
    final node = _selectedNode;
    if (node is! ParagraphNode) {
      return;
    }
    if (node.getMetadataValue(NodeMetadata.blockType) == codeAttribution) {
      // 已是代码块：再点一次不动作（避免嵌套插入出怪异状态）。
      return;
    }
    if (node.text.isEmpty) {
      editor.execute(<EditRequest>[
        ChangeParagraphBlockTypeRequest(
          nodeId: node.id,
          blockType: codeAttribution,
        ),
      ]);
      return;
    }

    final codeId = Editor.createNodeId();
    editor.execute(<EditRequest>[
      InsertNodeAtCaretRequest(
        node: ParagraphNode(
          id: codeId,
          text: AttributedText(''),
          metadata: const <String, dynamic>{
            NodeMetadata.blockType: codeAttribution,
          },
        ),
      ),
    ]);
    // InsertNodeAtCaretCommand 在跨节点选区等场景会静默拒绝（源码实测），
    // 确认节点真的落位后才能移光标 —— 对不存在的 nodeId 移光标会留下
    // 悬挂选区，后续渲染直接崩。
    if (document.getNodeById(codeId) == null) {
      return;
    }
    editor.execute(<EditRequest>[
      ChangeSelectionRequest(
        DocumentSelection.collapsed(
          position: DocumentPosition(
            nodeId: codeId,
            nodePosition: const TextNodePosition(offset: 0),
          ),
        ),
        SelectionChangeType.insertContent,
        SelectionReason.userInteraction,
      ),
    ]);
  }

  /// 插入分隔线（HorizontalRule 节点）。插到光标处：空段落原地变、
  /// 行尾插后面、行中劈开 —— InsertNodeAtCaretRequest 内建了这些分支。
  void _insertDivider() {
    if (composer.selection == null) {
      return;
    }
    if (composer.selection!.base.nodeId != composer.selection!.extent.nodeId) {
      return;
    }
    if (document.getNodeById(composer.selection!.extent.nodeId)
        is! ParagraphNode) {
      return;
    }
    editor.execute(<EditRequest>[
      InsertNodeAtCaretRequest(
        node: HorizontalRuleNode(id: Editor.createNodeId()),
      ),
    ]);
  }

  // ---------------------------------------------------------------------------
  // 图片
  // ---------------------------------------------------------------------------

  /// 在当前节点之后插入图片，并垫一个空段落接住光标（图片块不可输入，
  /// 不垫的话插完图就没地方打字了）。
  ///
  /// [imageUrl] 是小记方言的相对路径（`assets/<noteId>/1.jpg`），存储与
  /// 渲染都直接用它，与早期版本的附件目录布局保持同构。
  void insertImageNode(String imageUrl) {
    final selection = composer.selection;
    final anchor = selection == null
        ? null
        : document.getNodeById(selection.extent.nodeId);
    final imageNode = ImageNode(id: Editor.createNodeId(), imageUrl: imageUrl);
    // 光标落点：图片后面的空段落。
    final trailing = ParagraphNode(
      id: Editor.createNodeId(),
      text: AttributedText(''),
    );

    if (anchor is ParagraphNode && anchor.text.isEmpty) {
      // 空段落直接变图片，不留空壳。replace 原地换节点，下标不变。
      final anchorIndex = document.getNodeIndexById(anchor.id);
      editor.execute(<EditRequest>[
        ReplaceNodeRequest(existingNodeId: anchor.id, newNode: imageNode),
        InsertNodeAtIndexRequest(nodeIndex: anchorIndex + 1, newNode: trailing),
        _caretRequest(trailing.id),
      ]);
      return;
    }

    final insertIndex = anchor == null
        ? document.nodeCount
        : document.getNodeIndexById(anchor.id) + 1;
    editor.execute(<EditRequest>[
      InsertNodeAtIndexRequest(nodeIndex: insertIndex, newNode: imageNode),
      InsertNodeAtIndexRequest(nodeIndex: insertIndex + 1, newNode: trailing),
      _caretRequest(trailing.id),
    ]);
  }

  /// 光标折叠到 [nodeId] 开头的选区请求。
  ChangeSelectionRequest _caretRequest(String nodeId) {
    return ChangeSelectionRequest(
      DocumentSelection.collapsed(
        position: DocumentPosition(
          nodeId: nodeId,
          nodePosition: const TextNodePosition(offset: 0),
        ),
      ),
      SelectionChangeType.insertContent,
      SelectionReason.userInteraction,
    );
  }

  // ---------------------------------------------------------------------------
  // 工具条激活态
  // ---------------------------------------------------------------------------

  /// 计算当前光标/选区对应的激活命令集合。
  ///
  /// 块级看 extent 节点类型；行内只在**展开选区**上判断 —— 折叠光标不猜
  /// （猜错比不亮更困惑，早期版本 2026-11 调研的定论）。
  Set<MarkdownCommand> computeActiveCommands() {
    final selection = composer.selection;
    if (selection == null) {
      return const <MarkdownCommand>{};
    }
    final node = document.getNodeById(selection.extent.nodeId);
    if (node is! TextNode) {
      return const <MarkdownCommand>{};
    }

    final active = <MarkdownCommand>{};
    if (node is ParagraphNode) {
      final blockType = node.getMetadataValue(NodeMetadata.blockType);
      if (blockType == header1Attribution) {
        active.add(MarkdownCommand.h1);
      } else if (blockType == header2Attribution) {
        active.add(MarkdownCommand.h2);
      } else if (blockType == header3Attribution) {
        active.add(MarkdownCommand.h3);
      } else if (blockType == blockquoteAttribution) {
        active.add(MarkdownCommand.quote);
      }
    }
    if (node is TaskNode) {
      active.add(MarkdownCommand.todo);
    }
    if (node is ListItemNode) {
      active.add(node.type == ListItemType.ordered
          ? MarkdownCommand.ordered
          : MarkdownCommand.bullet);
    }

    // 行内格式：
    //  - 折叠光标：读 composer 的「下一次输入样式」。用户在 Aa 面板点的
    //    加粗/斜体就写在这里，不读的话按钮不点亮、看起来像没生效；
    //  - 展开选区：样式覆盖整个选区才点亮。
    if (selection.isCollapsed) {
      final Set<Attribution> input = composer.preferences.currentAttributions;
      if (input.contains(boldAttribution)) {
        active.add(MarkdownCommand.bold);
      }
      if (input.contains(italicsAttribution)) {
        active.add(MarkdownCommand.italic);
      }
      if (input.contains(strikethroughAttribution)) {
        active.add(MarkdownCommand.strike);
      }
      if (input.contains(codeAttribution)) {
        active.add(MarkdownCommand.code);
      }
      if (input.contains(highlightAttribution)) {
        active.add(MarkdownCommand.highlight);
      }
    } else if (selection.base.nodeId == selection.extent.nodeId) {
      final baseOffset =
          (selection.base.nodePosition as TextNodePosition).offset;
      final extentOffset =
          (selection.extent.nodePosition as TextNodePosition).offset;
      final lo = baseOffset < extentOffset ? baseOffset : extentOffset;
      final hi = baseOffset < extentOffset ? extentOffset : baseOffset;
      if (_covers(node.text, boldAttribution, lo, hi)) {
        active.add(MarkdownCommand.bold);
      }
      if (_covers(node.text, italicsAttribution, lo, hi)) {
        active.add(MarkdownCommand.italic);
      }
      if (_covers(node.text, strikethroughAttribution, lo, hi)) {
        active.add(MarkdownCommand.strike);
      }
      if (_covers(node.text, codeAttribution, lo, hi)) {
        active.add(MarkdownCommand.code);
      }
      if (_covers(node.text, highlightAttribution, lo, hi)) {
        active.add(MarkdownCommand.highlight);
      }
      final link = node.text.spans
          .getAllAttributionsAt(lo)
          .whereType<LinkAttribution>()
          .firstOrNull;
      if (link != null && _coversRange(node.text.spans, link, lo, hi)) {
        active.add(MarkdownCommand.link);
      }
    }
    return active;
  }

  /// [attr] 是否从 [lo] 到 [hi) 全程覆盖。
  ///
  /// SpanRange 的 end 是**闭区间**上界（序列化器里取整段要 +1，实测），
  /// 所以判覆盖用 `range.end >= hi - 1`。
  bool _covers(AttributedText text, Attribution attr, int lo, int hi) {
    if (lo >= text.length) {
      return false;
    }
    return _coversRange(text.spans, attr, lo, hi);
  }

  bool _coversRange(AttributedSpans spans, Attribution attr, int lo, int hi) {
    if (!spans.hasAttributionAt(lo, attribution: attr)) {
      return false;
    }
    final range = spans.getAttributedRange(<Attribution>{attr}, lo);
    return range.start <= lo && range.end >= hi - 1;
  }
}
