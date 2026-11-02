import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 标签胶囊（`#标签`）。
///
/// 列表卡片、详情页底部标签栏共用这一个规格：`accentBg` 底、5 圆角、
/// 0.5 描边、12 号中等字重。之前两处各写一份，颜色和高度差一两像素，
/// 看起来就不是同一个控件。
class TagChip extends StatelessWidget {
  const TagChip({super.key, required this.label, this.isOverflow = false});

  final String label;

  /// 「+N」收纳 chip：中性灰，与真标签（accent 蓝）区分开。
  final bool isOverflow;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: colors.accentBg,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: colors.chipBorder.withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      // 不能用 Container 的 alignment：它会让容器撑满父级约束，
      // 在 Wrap 里就会变成一条通栏色块。widthFactor: 1 只取文字宽度。
      child: Center(
        widthFactor: 1,
        child: Text(
          isOverflow ? label : '#$label',
          style: TextStyle(
            fontSize: 12,
            height: 1,
            letterSpacing: 0.2,
            fontWeight: AppWeight.medium,
            color: isOverflow ? colors.secondary : colors.accent,
          ),
        ),
      ),
    );
  }
}
