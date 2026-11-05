import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 待办勾选框：详情编辑态、阅读渲染、首页摘要共用同一个视觉规格。
///
/// 之前三处各画一套：编辑态是自绘 20dp 圆角框、阅读态用 Material 图标、
/// 首页摘要用 ☐/☑ 字符——同一个待办在列表和详情里长得不一样（用户反馈）。
/// 统一成 Material 的方框图标后，三处的框大小、颜色、与文字的间距完全一致。
class TaskCheckBox extends StatelessWidget {
  const TaskCheckBox({
    super.key,
    required this.checked,
    this.onTap,
    this.size = 20,
  });

  /// 是否已勾选。
  final bool checked;

  /// 点击回调；为空时是纯展示（首页摘要）。
  final VoidCallback? onTap;

  /// 勾选框边长（与正文 15.5 字号的视觉重量匹配）。
  final double size;

  /// 勾选框与文字之间的距离（详情、首页共用）。
  static const double gap = 6;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final Widget icon = Icon(
      checked ? Icons.check_box : Icons.check_box_outline_blank,
      size: size,
      color: checked ? colors.accent : colors.secondary,
    );
    if (onTap == null) {
      return icon;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: icon,
    );
  }
}
