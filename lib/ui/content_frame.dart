import 'package:flutter/material.dart';

/// 页面内容的统一宽度约束。
///
/// 手机上是全宽；平板横屏、桌面窗口下如果继续铺满，表单和列表会被拉成
/// 超长的一行，阅读动线就散了。所有「设置 / 表单 / 单列内容」页面统一用
/// 它包一层即可 —— 将来做平板或 PC 端时，只需要调整这里的 [maxWidth]
/// （或按 `MediaQuery.sizeOf` 给不同断点），不用逐页改布局。
class ContentFrame extends StatelessWidget {
  const ContentFrame({
    super.key,
    required this.child,
    this.maxWidth = 480,
  });

  final Widget child;

  /// 内容最大宽度（dp）。超过这个宽度就居中留白。
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
