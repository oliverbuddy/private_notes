import 'package:super_editor/super_editor.dart';

/// 附件识别：整段只有一条本地附件链接 `[文件名](assets/…)` 时成立。
///
/// 展示层（`AttachmentComponentBuilder`）和编辑逻辑共用这一个判定，
/// 避免「渲染成卡片、删除时却不认它是附件」的两套标准。
///
/// 附件在模型里就是普通段落（ParagraphNode + LinkAttribution），所以
/// 它一直是个真正的文本块：光标、选区、IME 输入都走官方文本链路。
/// 展示层的卡片外观只影响「怎么画」，不影响「怎么编辑」。
abstract final class AttachmentEditing {
  /// 判断一段带样式的文本是否整体就是一个本地附件链接。
  static LinkAttribution? linkOfText(AttributedText text) {
    if (text.isEmpty) {
      return null;
    }
    final link = text.spans
        .getAllAttributionsAt(0)
        .whereType<LinkAttribution>()
        .firstOrNull;
    if (link == null || !link.plainTextUri.startsWith('assets/')) {
      return null;
    }
    final range = text.spans.getAttributedRange({link}, 0);
    if (range.start != 0 || range.end != text.length - 1) {
      return null;
    }
    return link;
  }

  /// 节点级别的判定（段落 + 整段附件链接）。
  static LinkAttribution? linkOf(DocumentNode node) {
    if (node is! ParagraphNode) {
      return null;
    }
    return linkOfText(node.text);
  }

  /// 该节点是否渲染成附件卡片。
  static bool isAttachmentNode(DocumentNode node) => linkOf(node) != null;
}
