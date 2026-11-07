import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 页面内容的统一宽度约束（响应式）。
///
/// 手机全宽；平板/桌面按 [AppBreakpoints.contentMaxWidth] 收窄并居中，
/// 避免设置列表、表单被拉成超长一行。后续做 Pad 双栏、PC 侧栏时，
/// 只改断点或在这里加分支，不用逐页改布局。
class ContentFrame extends StatelessWidget {
  const ContentFrame({
    super.key,
    required this.child,
    this.maxWidth,
  });

  final Widget child;

  /// 覆盖默认断点宽度（一般不用传）。
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.sizeOf(context).width;
    final double width =
        maxWidth ?? AppBreakpoints.contentMaxWidth(screenWidth);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: child,
      ),
    );
  }
}
