import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/super_editor.dart';

import '../../data/note_repository.dart';
import '../../theme/app_theme.dart';
import '../../ui/show_sheet.dart';
import 'attachment_editing.dart';

/// 文件附件卡片。
///
/// 存储层是 `[文件名](assets/…)`（与旧版兼容）。之前为了「卡片」外观把
/// 整行换成了 `BoxComponent`，代价是这一块不再是文本组件：光标一旦带着
/// 文本位置落进来，布局/光标/IME 每帧抛
/// 「Expected nodePosition of type UpstreamDownstreamNodePosition」，
/// 表现为「回车/删除附件时页面异常、卡住」（用户反馈）。
///
/// 这里回到「文本 + 卡片外观」的组合：正文仍是真正的 `TextComponent`
/// （文件名可选中、光标位置、IME 输入全部走官方链路，不会再出现位置类型
/// 冲突），外面套一层卡片底色、文件图标和副标题。点击卡片打开操作弹层，
/// 与之前的手感一致。
class AttachmentComponentBuilder implements ComponentBuilder {
  const AttachmentComponentBuilder({
    required this.repository,
    required this.editor,
    required this.onShowActions,
  });

  final NoteRepository repository;
  final Editor editor;
  final void Function(BuildContext context, String nodeId, String name, String url)
      onShowActions;

  static const ParagraphComponentBuilder _delegate = ParagraphComponentBuilder();

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(
    Document document,
    DocumentNode node,
  ) {
    if (node is! ParagraphNode || node.text.isEmpty) {
      return null;
    }
    if (AttachmentEditing.linkOf(node) == null) {
      return null;
    }
    // 复用默认段落 ViewModel：字号、页边距、选区/软键盘信息全部按
    // stylesheet 走；差别只在外层组件怎么画。
    return _delegate.createViewModel(document, node);
  }

  @override
  Widget? createComponent(
    SingleColumnDocumentComponentContext componentContext,
    SingleColumnLayoutComponentViewModel componentViewModel,
  ) {
    if (componentViewModel is! ParagraphComponentViewModel) {
      return null;
    }
    final link = AttachmentEditing.linkOfText(componentViewModel.text);
    if (link == null) {
      return null;
    }
    return _AttachmentCardComponent(
      componentKey: componentContext.componentKey,
      viewModel: componentViewModel,
      repository: repository,
      url: link.plainTextUri,
      onTap: () => onShowActions(
        componentContext.context,
        componentViewModel.nodeId,
        componentViewModel.text.toPlainText().trim(),
        link.plainTextUri,
      ),
    );
  }
}

/// 卡片外观 + 一个真正可编辑的 [TextComponent]。
///
/// 组件契约（`getPositionAtOffset` / 选区 / 光标）由
/// [ProxyTextDocumentComponent] 转发给内部文本组件，所以这一块仍然是
/// 标准文本块；卡片底色、图标、副标题只是它的装饰层。
class _AttachmentCardComponent extends StatefulWidget {
  const _AttachmentCardComponent({
    required this.componentKey,
    required this.viewModel,
    required this.repository,
    required this.url,
    required this.onTap,
  });

  final GlobalKey componentKey;
  final ParagraphComponentViewModel viewModel;
  final NoteRepository repository;
  final String url;
  final VoidCallback onTap;

  @override
  State<_AttachmentCardComponent> createState() =>
      _AttachmentCardComponentState();
}

class _AttachmentCardComponentState extends State<_AttachmentCardComponent> {
  final GlobalKey _innerTextComponentKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final String path = widget.repository.store.absoluteAssetPath(widget.url);
    final bool exists = File(path).existsSync();
    final ParagraphComponentViewModel vm = widget.viewModel;

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Material(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.block),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          onLongPress: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    exists ? Icons.insert_drive_file_rounded : Icons.error_outline_rounded,
                    size: AppIcon.action,
                    color: exists ? colors.accent : colors.danger,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      // 文件名是真文本：光标、选区、输入都落在这里。
                      ProxyTextDocumentComponent(
                        key: widget.componentKey,
                        textComponentKey: _innerTextComponentKey,
                        child: TextComponent(
                          key: _innerTextComponentKey,
                          text: vm.text,
                          textDirection: vm.textDirection,
                          textAlign: vm.textAlignment,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textStyleBuilder: (Set<Attribution> _) => TextStyle(
                            fontSize: AppFontSize.value,
                            height: 1.3,
                            fontWeight: AppWeight.medium,
                            color: colors.text,
                          ),
                          textSelection: vm.selection,
                          selectionColor: vm.selectionColor,
                          highlightWhenEmpty: vm.highlightWhenEmpty,
                          underlines: vm.createUnderlines(),
                          inlineWidgetBuilders: vm.inlineWidgetBuilders,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        exists ? '附件 · 点击查看' : '文件已丢失',
                        style: TextStyle(
                          fontSize: AppFontSize.badgeLg,
                          color: exists ? colors.tertiary : colors.danger,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Icon(Icons.chevron_right_rounded, size: AppIcon.chevron, color: colors.tertiary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 附件操作弹层：复制路径 / 从正文移除。
///
/// 单独抽成函数，组件只关心「点了要回调」，弹层不再依赖组件内部状态。
Future<void> showAttachmentActionsSheet({
  required BuildContext context,
  required NoteRepository repository,
  required Editor editor,
  required String nodeId,
  required String name,
  required String url,
}) async {
  final colors = AppColors.of(context);
  final String path = repository.store.absoluteAssetPath(url);
  final File file = File(path);
  final bool exists = file.existsSync();
  final String size = exists ? _formatSize(file.lengthSync()) : '文件已丢失';

  final action = await showXiaojiSheet<String>(
    context: context,
    builder: (BuildContext sheetContext) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                name,
                style: AppText.sheetTitle.copyWith(color: colors.text),
              ),
              const SizedBox(height: 6),
              Text(
                '附件 · $size',
                style: TextStyle(fontSize: AppFontSize.meta, color: colors.tertiary),
              ),
              const SizedBox(height: 14),
              Text(
                path,
                style: TextStyle(
                  fontSize: AppFontSize.meta,
                  height: 1.6,
                  color: colors.secondary,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: <Widget>[
                  Expanded(
                    child: AppSheetButton(
                      label: '复制路径',
                      background: colors.surface2,
                      foreground: colors.accent,
                      onTap: () => Navigator.of(sheetContext).pop('copy'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AppSheetButton(
                      label: '从正文移除',
                      background: colors.surface2,
                      foreground: colors.danger,
                      onTap: () => Navigator.of(sheetContext).pop('remove'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );

  if (action == 'copy') {
    await Clipboard.setData(ClipboardData(text: path));
  } else if (action == 'remove') {
    // 附件行就是文本行：清空这一行的文本即可（空段落仍保留，光标停在该行）。
    editor.execute(<EditRequest>[
      ReplaceNodeRequest(
        existingNodeId: nodeId,
        newNode: ParagraphNode(id: nodeId, text: AttributedText()),
      ),
      ChangeSelectionRequest(
        DocumentSelection.collapsed(
          position: DocumentPosition(
            nodeId: nodeId,
            nodePosition: const TextNodePosition(offset: 0),
          ),
        ),
        SelectionChangeType.placeCaret,
        SelectionReason.userInteraction,
      ),
    ]);
  }
}

String _formatSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
