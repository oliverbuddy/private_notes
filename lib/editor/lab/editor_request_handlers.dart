import 'dart:math' as math;
import 'dart:ui' show TextAffinity, TextPosition;

import 'package:super_editor/super_editor.dart';

import 'markdown_inline.dart';
import 'xiaoji_markdown.dart';

/// 小记内核的编辑请求拦截器。
///
/// 注册在 [defaultRequestHandlers] 之前：super_editor 的处理器链是
/// 「第一个返回非 null 的处理器生效」，这里只接管语义与默认实现不一致
/// 的块类型，其余请求原样交回默认链路（不复制、不重写 super_editor 逻辑）。
final List<EditRequestHandler> xiaojiRequestHandlers =
    List<EditRequestHandler>.unmodifiable(<EditRequestHandler>[
  _horizontalRuleHandler,
  _backspaceAtLineStartHandler,
  _codeFenceOpeningHandler,
  _codeBlockNewlineHandler,
  _blockquoteContinuationHandler,
]);

/// 行首退格统一按「并入上一行」处理。
///
/// 常规逻辑：光标在行首按退格 = 把这一行并到上一行，整行沿用上一行格式，
/// 光标停在拼接处（Word / Notion / 语雀一致）。
/// 内核的 `DeleteUpstreamCharacterCommand` 在 offset 0 会直接抛异常，
/// 部分输入法在行首发的正是「删一个字符」请求，结果是这下手势被吞掉、
/// 甚至删到上一行末尾的字符（用户反馈「正文行首退格和标题一样」）。
/// 这里在行首把它换成标准的「向上合并」，其余位置原样交回内核。
EditCommand? _backspaceAtLineStartHandler(Editor editor, EditRequest request) {
  if (request is! DeleteUpstreamCharacterRequest) {
    return null;
  }
  final DocumentSelection? selection = editor.composer.selection;
  if (selection == null || !selection.isCollapsed) {
    return null;
  }
  final NodePosition position = selection.extent.nodePosition;
  if (position is! TextNodePosition || position.offset != 0) {
    return null;
  }
  final DocumentNode? node =
      editor.document.getNodeById(selection.extent.nodeId);
  if (node is! ParagraphNode) {
    return null;
  }
  final DocumentNode? previous = editor.document.getNodeBeforeById(node.id);
  if (previous is! ParagraphNode) {
    return null;
  }
  return _MergeIntoPreviousLineCommand(node.id);
}

/// 把当前段落并入上一段（沿用上一段格式），光标停在拼接处。
///
/// 与内核「行首退格」的语义完全一致，只是不依赖 `DeleteUpstreamCharacter`
/// 那条在 offset 0 会抛异常的路径。
class _MergeIntoPreviousLineCommand extends EditCommand {
  const _MergeIntoPreviousLineCommand(this.nodeId);

  final String nodeId;

  @override
  HistoryBehavior get historyBehavior => HistoryBehavior.undoable;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    final MutableDocument document = context.document;
    final DocumentNode? node = document.getNodeById(nodeId);
    final DocumentNode? previous =
        node == null ? null : document.getNodeBeforeById(node.id);
    if (node is! ParagraphNode || previous is! ParagraphNode) {
      return;
    }
    final int caretOffset = previous.text.length;
    executor
      ..executeCommand(
        CombineParagraphsCommand(
          firstNodeId: previous.id,
          secondNodeId: node.id,
        ),
      )
      ..executeCommand(
        ChangeSelectionCommand(
          DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: previous.id,
              nodePosition: TextNodePosition(offset: caretOffset),
            ),
          ),
          SelectionChangeType.deleteContent,
          SelectionReason.userInteraction,
        ),
      )
      ..executeCommand(ChangeComposingRegionCommand(null));
  }
}

/// 组装小记内核。
///
/// 页面与测试共用这一个入口：官方默认请求处理器/反应管线保持不变，
/// 只在最前面插入 [xiaojiRequestHandlers]，避免「页面有一套管线、
/// 测试另写一套」导致两边行为不一致。
Editor createXiaojiEditor({
  required MutableDocument document,
  required MutableDocumentComposer composer,
  bool isHistoryEnabled = true,
}) {
  return Editor(
    editables: <String, Editable>{
      Editor.documentKey: document,
      Editor.composerKey: composer,
    },
    requestHandlers: <EditRequestHandler>[
      ...xiaojiRequestHandlers,
      ...List<EditRequestHandler>.from(defaultRequestHandlers),
    ],
    reactionPipeline: List<EditReaction>.from(defaultEditorReactions),
    historyGroupingPolicy: defaultMergePolicy,
    isHistoryEnabled: isHistoryEnabled,
  );
}

/// 手打分割线（`---` / `***` / `___`）后回车 → 生成真正的分割线。
///
/// 主流编辑器（Typora / Obsidian / 语雀）都是这个语义：整段只有一个
/// 分割线记号时，回车就把它变成分隔线。只认「整段文本就是分割线」，
/// `- 列表项` 这类带正文的行不受影响；只有一个 `-` 也不会命中（需要 3 个）。
EditCommand? _horizontalRuleHandler(Editor editor, EditRequest request) {
  if (request is! InsertNewlineAtCaretRequest) {
    return null;
  }
  final selection = editor.composer.selection;
  if (selection == null || !selection.isCollapsed) {
    return null;
  }
  final node = editor.document.getNodeById(selection.extent.nodeId);
  if (node is! ParagraphNode) {
    return null;
  }
  final Object? blockType = node.getMetadataValue(NodeMetadata.blockType);
  if (blockType != null && blockType != paragraphAttribution) {
    return null;
  }
  final position = selection.extent.nodePosition;
  if (position is! TextNodePosition) {
    return null;
  }
  final String text = node.text.toPlainText();
  if (position.offset != text.length || !isHorizontalRuleLine(text)) {
    return null;
  }
  return _HorizontalRuleCommand(
    nodeId: node.id,
    newNodeId: request.newNodeId,
  );
}

/// 把「手打的分割线段落」换成 [HorizontalRuleNode]，并在其后垫一个空段落
/// 接住光标（分割线本身没有文本光标）。
class _HorizontalRuleCommand extends EditCommand {
  const _HorizontalRuleCommand({
    required this.nodeId,
    required this.newNodeId,
  });

  final String nodeId;
  final String newNodeId;

  @override
  HistoryBehavior get historyBehavior => HistoryBehavior.undoable;

  @override
  String describe() => 'Horizontal rule - $nodeId';

  @override
  void execute(EditContext context, CommandExecutor executor) {
    executor
      ..executeCommand(
        ReplaceNodeCommand(
          existingNodeId: nodeId,
          newNode: HorizontalRuleNode(id: nodeId),
        ),
      )
      ..executeCommand(
        InsertNodeAfterNodeCommand(
          existingNodeId: nodeId,
          newNode: ParagraphNode(id: newNodeId, text: AttributedText()),
        ),
      )
      ..executeCommand(
        ChangeSelectionCommand(
          DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: newNodeId,
              nodePosition: const TextNodePosition(offset: 0),
            ),
          ),
          SelectionChangeType.insertContent,
          SelectionReason.userInteraction,
        ),
      );
  }
}

/// 手打代码围栏（``` / ```dart）后回车 → 直接生成代码块。
///
/// 主流编辑器（Typora / Obsidian / 语雀）都是这个语义：用户手打围栏是
/// 想写代码，不该在正文里留下一行字面量 ```。只在「整段文字就是一个
/// 围栏」时生效，` ``` 后面还有内容的普通句子不受影响。
/// 语言标记（```dart）会写进 [kCodeLanguageMetadata]，与工具条插入的
/// 代码块走同一份元数据，序列化后是 ` ```dart `。
EditCommand? _codeFenceOpeningHandler(Editor editor, EditRequest request) {
  if (request is! InsertNewlineAtCaretRequest) {
    return null;
  }
  final selection = editor.composer.selection;
  if (selection == null || !selection.isCollapsed) {
    return null;
  }
  final node = editor.document.getNodeById(selection.extent.nodeId);
  if (node is! ParagraphNode) {
    return null;
  }
  final Object? blockType = node.getMetadataValue(NodeMetadata.blockType);
  if (blockType != null && blockType != paragraphAttribution) {
    return null;
  }
  final position = selection.extent.nodePosition;
  if (position is! TextNodePosition) {
    return null;
  }
  final String text = node.text.toPlainText();
  if (position.offset != text.length) {
    return null;
  }
  final String? language = matchCodeFenceOpening(text);
  if (language == null) {
    return null;
  }
  return _StartCodeBlockCommand(
    nodeId: node.id,
    language: language,
  );
}

/// 把「手打的围栏段落」就地换成空代码块，光标落在块内。
class _StartCodeBlockCommand extends EditCommand {
  const _StartCodeBlockCommand({required this.nodeId, required this.language});

  final String nodeId;

  /// 围栏上写的语言；空字符串表示没写。
  final String language;

  @override
  HistoryBehavior get historyBehavior => HistoryBehavior.undoable;

  @override
  String describe() => 'Start code block - $nodeId';

  @override
  void execute(EditContext context, CommandExecutor executor) {
    final ParagraphNode node =
        context.document.getNodeById(nodeId)! as ParagraphNode;
    executor
      ..executeCommand(
        ReplaceNodeCommand(
          existingNodeId: nodeId,
          newNode: ParagraphNode(
            id: node.id,
            text: AttributedText(),
            metadata: <String, dynamic>{
              ...node.metadata,
              NodeMetadata.blockType: codeAttribution,
              if (language.isNotEmpty) kCodeLanguageMetadata: language,
            },
          ),
        ),
      )
      ..executeCommand(
        ChangeSelectionCommand(
          DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: nodeId,
              nodePosition: const TextNodePosition(offset: 0),
            ),
          ),
          SelectionChangeType.insertContent,
          SelectionReason.userInteraction,
        ),
      );
  }
}

/// 代码块（围栏）里的回车语义。
///
/// 内核默认会把段落一分为二，新节点复制 `blockType: code` —— 但序列化时
/// 每个代码节点各写一对围栏，用户回一次车就多出一对 ```，代码块被截成
/// 两段（实测：`\`\`\`dart` 里回车会得到「代码块 + 普通空段落」）。
/// 主流编辑器（Typora / Notion / VS Code）在代码块内回车只插入一个
/// 换行字符，光标留在同一块里；块外回车才新建段落。这里对齐该语义。
EditCommand? _codeBlockNewlineHandler(Editor editor, EditRequest request) {
  if (request is! InsertNewlineAtCaretRequest) {
    return null;
  }
  final selection = editor.composer.selection;
  if (selection == null || selection.base.nodeId != selection.extent.nodeId) {
    return null;
  }
  final node = editor.document.getNodeById(selection.extent.nodeId);
  if (node is! ParagraphNode ||
      node.getMetadataValue(NodeMetadata.blockType) != codeAttribution) {
    return null;
  }
  final basePosition = selection.base.nodePosition;
  final extentPosition = selection.extent.nodePosition;
  if (basePosition is! TextNodePosition ||
      extentPosition is! TextNodePosition) {
    return null;
  }

  // 光标停在代码块的**末尾空行**上再回车：结束代码块，这一行变回正文。
  // 与列表项/引用「空行回车退出」一致（用户要求）。中间的空行仍按普通
  // 换行处理，避免代码块被意外截断。
  //
  // 解析器补的合成换行已在 deserialize 阶段去掉，所以「末尾空行」就是
  // 文本以单个 `\n` 结尾（`line1\n`＝第一行 + 一个空行）；光标在最后一行
  // 末尾时文本还不带 `\n`，那时回车只是普通换行，不会误退出。
  final int offset = extentPosition.offset;
  final String plain = node.text.toPlainText();
  final int lineStart =
      offset == 0 ? 0 : plain.lastIndexOf('\n', offset - 1) + 1;
  final bool onEmptyLastLine = offset == plain.length &&
      plain.endsWith('\n') &&
      plain.substring(lineStart).trim().isEmpty;
  if (onEmptyLastLine) {
    // 去掉末尾所有换行：退出用的那行空行不应留在代码块里。
    int contentEnd = plain.length;
    while (contentEnd > 0 && plain[contentEnd - 1] == '\n') {
      contentEnd -= 1;
    }
    return _ExitCodeBlockCommand(
      nodeId: node.id,
      contentEnd: contentEnd,
      newNodeId: request.newNodeId,
    );
  }

  return _InsertNewlineInCodeBlockCommand(
    nodeId: node.id,
    start: math.min(basePosition.offset, extentPosition.offset),
    hasSelection: !selection.isCollapsed,
  );
}

/// 结束代码块：保留上方代码内容，把末尾空行拆成普通段落。
///
/// 空代码块（没有内容）直接把当前节点改回正文，避免留下一个空代码框。
class _ExitCodeBlockCommand extends EditCommand {
  const _ExitCodeBlockCommand({
    required this.nodeId,
    required this.contentEnd,
    required this.newNodeId,
  });

  final String nodeId;

  /// 代码内容的结束位置（去掉末尾用于退出的那个换行）。
  final int contentEnd;

  final String newNodeId;

  @override
  HistoryBehavior get historyBehavior => HistoryBehavior.undoable;

  @override
  String describe() => 'Exit code block - $nodeId';

  @override
  void execute(EditContext context, CommandExecutor executor) {
    if (contentEnd <= 0) {
      executor
        ..executeCommand(
          ChangeParagraphBlockTypeCommand(
            nodeId: nodeId,
            blockType: paragraphAttribution,
          ),
        )
        ..executeCommand(
          ChangeSelectionCommand(
            DocumentSelection.collapsed(
              position: DocumentPosition(
                nodeId: nodeId,
                nodePosition: const TextNodePosition(offset: 0),
              ),
            ),
            SelectionChangeType.placeCaret,
            SelectionReason.userInteraction,
          ),
        );
      return;
    }

    final ParagraphNode node =
        context.document.getNodeById(nodeId)! as ParagraphNode;
    final String trimmed = node.text.toPlainText().substring(0, contentEnd);
    executor
      ..executeCommand(
        ReplaceNodeCommand(
          existingNodeId: nodeId,
          newNode: ParagraphNode(
            id: node.id,
            text: AttributedText(trimmed),
            metadata: node.metadata,
          ),
        ),
      )
      ..executeCommand(
        InsertNodeAfterNodeCommand(
          existingNodeId: nodeId,
          newNode: ParagraphNode(id: newNodeId, text: AttributedText()),
        ),
      )
      ..executeCommand(
        ChangeSelectionCommand(
          DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: newNodeId,
              nodePosition: const TextNodePosition(offset: 0),
            ),
          ),
          SelectionChangeType.insertContent,
          SelectionReason.userInteraction,
        ),
      );
  }
}

/// 在代码块内插入字面换行：可选先删掉选中内容，再把光标移到换行之后。
class _InsertNewlineInCodeBlockCommand extends EditCommand {
  const _InsertNewlineInCodeBlockCommand({
    required this.nodeId,
    required this.start,
    required this.hasSelection,
  });

  final String nodeId;

  /// 选区起点（展开选区时取较小偏移）。
  final int start;

  final bool hasSelection;

  @override
  HistoryBehavior get historyBehavior => HistoryBehavior.undoable;

  @override
  String describe() => 'Insert newline inside code block - $nodeId @ $start';

  @override
  void execute(EditContext context, CommandExecutor executor) {
    if (hasSelection) {
      executor.executeCommand(
        DeleteSelectionCommand(affinity: TextAffinity.upstream),
      );
    }
    executor
      ..executeCommand(
        InsertTextCommand(
          documentPosition: DocumentPosition(
            nodeId: nodeId,
            nodePosition: TextNodePosition(offset: start),
          ),
          textToInsert: '\n',
          attributions: const <Attribution>{},
        ),
      )
      ..executeCommand(
        ChangeSelectionCommand(
          DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: nodeId,
              nodePosition: TextNodePosition(offset: start + 1),
            ),
          ),
          SelectionChangeType.insertContent,
          SelectionReason.userInteraction,
        ),
      );
  }
}

/// 引用块（以及后续同类「块级段落」）的回车续行语义。
///
/// super_editor 默认在段落**末尾**回车时 `replicateExistingMetadata: false`
/// （见 `DefaultInsertNewlineAtCaretCommand`），于是 `> 引用一行` 末尾回车
/// 会得到一个普通段落 —— 引用块从第二行就断掉（用户反馈）。主流编辑器
/// （语雀 / GitHub / Notion）的语义是：
///  - 有内容时回车：继续引用，新行仍是引用块；
///  - 空引用行再回车：退出引用，回到普通段落。
/// 这与列表项的续行 / 退出语义一致，用户不需要记两套规则。
EditCommand? _blockquoteContinuationHandler(
    Editor editor, EditRequest request) {
  if (request is! InsertNewlineAtCaretRequest) {
    return null;
  }
  final selection = editor.composer.selection;
  if (selection == null || !selection.isCollapsed) {
    // 展开选区交给默认链路：它先删除选中内容再插入换行。
    return null;
  }
  final position = selection.extent.nodePosition;
  if (position is! TextNodePosition) {
    return null;
  }
  final node = editor.document.getNodeById(selection.extent.nodeId);
  if (node is! ParagraphNode ||
      node.getMetadataValue(NodeMetadata.blockType) != blockquoteAttribution) {
    return null;
  }

  if (node.text.isEmpty) {
    // 空引用行再回车 = 退出引用。
    return ChangeParagraphBlockTypeCommand(
      nodeId: node.id,
      blockType: paragraphAttribution,
    );
  }
  return _SplitBlockquoteParagraphCommand(
    nodeId: node.id,
    splitPosition: position,
    newNodeId: request.newNodeId,
  );
}

/// 拆分段落（保留块类型），并把光标放到新段落行首。
///
/// 不用官方 `DefaultInsertNewlineAtCaretCommand`：它在「末尾回车」时
/// 不复制 metadata，新段落的块类型会掉回普通段落。
class _SplitBlockquoteParagraphCommand extends EditCommand {
  const _SplitBlockquoteParagraphCommand({
    required this.nodeId,
    required this.splitPosition,
    required this.newNodeId,
  });

  final String nodeId;
  final TextPosition splitPosition;
  final String newNodeId;

  @override
  HistoryBehavior get historyBehavior => HistoryBehavior.undoable;

  @override
  void execute(EditContext context, CommandExecutor executor) {
    executor
      ..executeCommand(
        SplitParagraphCommand(
          nodeId: nodeId,
          splitPosition: splitPosition,
          newNodeId: newNodeId,
          replicateExistingMetadata: true,
        ),
      )
      ..executeCommand(
        ChangeSelectionCommand(
          DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: newNodeId,
              nodePosition: const TextNodePosition(offset: 0),
            ),
          ),
          SelectionChangeType.insertContent,
          SelectionReason.userInteraction,
        ),
      );
  }
}
