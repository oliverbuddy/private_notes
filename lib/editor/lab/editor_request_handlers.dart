import 'dart:math' as math;
import 'dart:ui' show TextAffinity, TextPosition;

import 'package:super_editor/super_editor.dart';

/// 小记内核的编辑请求拦截器。
///
/// 注册在 [defaultRequestHandlers] 之前：super_editor 的处理器链是
/// 「第一个返回非 null 的处理器生效」，这里只接管语义与默认实现不一致
/// 的块类型，其余请求原样交回默认链路（不复制、不重写 super_editor 逻辑）。
final List<EditRequestHandler> xiaojiRequestHandlers =
    List<EditRequestHandler>.unmodifiable(<EditRequestHandler>[
  _codeBlockNewlineHandler,
  _blockquoteContinuationHandler,
]);

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
