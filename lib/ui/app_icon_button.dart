import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'pressable.dart';

/// 鸿蒙规范的图标按钮。
///
/// 统一约束（此前各页面各写一套 48/44/40 热区与 48 选中底）：
/// - 点击热区 [hitSize] 默认 48vp（最小 40vp）；
/// - 图标默认 24vp，落在 22vp 活动区内；
/// - 选中态只画 36vp 圆形底，不再铺满整个 48 热区；
/// - 常规色用正文色，选中用主色，禁用用三级文字色。
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.color,
    this.iconSize = AppIcon.action,
    this.hitSize = AppSize.navBar,
    this.selected = false,
    this.backgroundSize = 36,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;

  /// 不传时按 [selected] 自动取主色 / 正文色。
  final Color? color;

  final double iconSize;
  final double hitSize;
  final bool selected;

  /// 选中态圆形底的直径。默认 36，明显小于 48 热区。
  final double backgroundSize;

  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Color foreground =
        color ?? (selected ? colors.accent : colors.text);

    final Widget button = AppPressable(
      onTap: onTap,
      pressedScale: 0.92,
      child: SizedBox(
        width: hitSize,
        height: hitSize,
        child: Center(
          child: Container(
            width: backgroundSize,
            height: backgroundSize,
            decoration: selected
                ? BoxDecoration(
                    color: colors.accentBg,
                    shape: BoxShape.circle,
                  )
                : null,
            child: Icon(icon, size: iconSize, color: foreground),
          ),
        ),
      ),
    );

    if (tooltip == null) {
      return button;
    }
    return Tooltip(message: tooltip!, child: button);
  }
}

/// 全站统一的返回按钮。
///
/// 鸿蒙返回图标是细线 chevron（24vp、1.5vp 描边），不是 iOS 的粗箭头。
/// 统一用 [Icons.chevron_left_rounded]，颜色取正文主色，48vp 热区。
class AppBackButton extends StatelessWidget {
  const AppBackButton({
    super.key,
    this.onTap,
    this.color,
  });

  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return AppIconButton(
      icon: Icons.chevron_left_rounded,
      onTap: onTap ?? () => Navigator.of(context).maybePop(),
      color: color ?? colors.text,
      tooltip: '返回',
    );
  }
}
