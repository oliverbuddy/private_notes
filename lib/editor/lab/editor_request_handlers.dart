import 'dart:ui' show TextPosition;

import 'package:super_editor/super_editor.dart';

/// 小记内核的编辑请求拦截器。
///
/// 注册在 [defaultRequestHandlers] 之前：super_editor 的处理器链是
/// 「第一个返回非 null 的处理器生效」，这里只接管语义与默认实现不一致
/// 的块类型，其余请求原样交回默认链路（不复制、不重写 super_editor 逻辑）。
final List<EditRequestHandler> xiaojiRequestHandlers =
    List<EditRequestHandler>.unmodifiable(<EditRequestHandler>[
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

/// 引用块（以及后续同类「块级段落」）的回车续行语义。
///
/// super_editor 默认在段落**末尾**回车时 `replicateExistingMetadata: false`
/// （见 `DefaultInsertNewlineAtCaretCommand`），于是 `> 引用一行` 末尾回车
/// 会得到一个普通段落 —— 引用块从第二行就断掉（用户反馈）。主流编辑器
/// （语雀 / GitHub / Notion）的语义是：
///  - 有内容时回车：继续引用，新行仍是引用块；
///  - 空引用行再回车：退出引用，回到普通段落。
/// 这与列表项的续行 / 退出语义一致，用户不需要记两套规则。
EditCommand? _blockquoteContinuationHandler(Editor editor, EditRequest request) {
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
