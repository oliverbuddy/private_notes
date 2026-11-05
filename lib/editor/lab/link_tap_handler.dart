import 'package:super_editor/super_editor.dart';

import '../../util/external_link.dart';

/// 小记的内容点击策略：链接跳转 + 双击不选词。
///
/// 链接：super_editor 自带的 [SuperEditorLaunchLinkTapHandler] 只在
/// `composer.isInInteractionMode == true` 时打开链接 —— 小记是常驻编辑态，
/// 这个条件永远不成立，于是点链接只会挪光标（用户反馈「链接点不开」）。
/// 这里替换成「点中链接就交给系统浏览器」的轻量实现：
///  - 命中 LinkAttribution 且协议可打开 → 启动外部 App，并 halt（不挪光标）；
///  - 其余情况继续交给编辑器处理（正常落光标）。
///
/// 双击：super_editor 默认会选中一个词并立刻弹出「复制/剪切/粘贴/全选」
/// 工具条。小记是「打开即可写」的常驻编辑页，双击多数只是快速落光标，
/// 弹工具条会打断阅读（用户反馈）。主流移动笔记里选词统一走**长按**，
/// 所以这里直接 halt 双击，让它等价于一次普通点击。
class XiaojiLinkTapHandler extends ContentTapDelegate {
  XiaojiLinkTapHandler(this.document);

  final Document document;

  @override
  TapHandlingInstruction onTap(DocumentTapDetails details) {
    final DocumentPosition? position =
        details.documentLayout.getDocumentPositionNearestToOffset(
      details.layoutOffset,
    );
    if (position == null) {
      return TapHandlingInstruction.continueHandling;
    }
    final nodePosition = position.nodePosition;
    if (nodePosition is! TextNodePosition) {
      return TapHandlingInstruction.continueHandling;
    }
    final DocumentNode? node = document.getNodeById(position.nodeId);
    if (node is! TextNode) {
      return TapHandlingInstruction.continueHandling;
    }

    final int offset = nodePosition.offset;
    if (offset < 0 || offset >= node.text.length) {
      return TapHandlingInstruction.continueHandling;
    }
    // 命中位置可能同时带多个属性（标签/链接），只关心链接。
    for (final Attribution attribution
        in node.text.getAllAttributionsAt(offset)) {
      if (attribution is! LinkAttribution) {
        continue;
      }
      final String url = attribution.launchableUri.toString();
      if (!isExternalLinkUrl(url)) {
        continue;
      }
      openExternalLinkQuietly(url);
      // 用户点的是链接：不挪光标，交给系统浏览器。
      return TapHandlingInstruction.halt;
    }
    return TapHandlingInstruction.continueHandling;
  }

  /// 双击不进入选词，也不弹选择工具条。
  ///
  /// 需要选中文字时用长按（Android 标准交互）；双击的首次点击已经
  /// 把光标落好，halt 之后选区保持不变，不会多出任何浮层。
  @override
  TapHandlingInstruction onDoubleTap(DocumentTapDetails details) {
    return TapHandlingInstruction.halt;
  }
}
