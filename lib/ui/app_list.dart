import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'pressable.dart';

/// HarmonyOS「插入式分组列表」容器。
///
/// 设置、关于、标签管理、回收站等页面此前各自手写「白卡 + 分隔线 +
/// 圆角 + 行高」，数值逐渐漂移。这里收拢成一个组件：
/// - 分组标题 12vp 灰色，位于卡片之上；
/// - 卡片 16vp 连续圆角、白色/深灰底、官方 8/2/8% 浅阴影；
/// - 行与行之间 0.5vp 分隔线，左侧内缩 16；
/// - 分组说明 12vp 灰色，位于卡片之下。
///
/// 以后做 Pad/PC 时只需要在页面外层套 [ContentFrame]，这个组件不用改。
class AppListSection extends StatelessWidget {
  const AppListSection({
    super.key,
    required this.children,
    this.header,
    this.footer,
    this.margin = EdgeInsets.zero,
  });

  final List<Widget> children;
  final String? header;
  final String? footer;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (header != null)
            Padding(
              padding: const EdgeInsets.only(left: AppSpace.lg, bottom: 6),
              child: Text(
                header!,
                style: AppText.caption.copyWith(color: colors.secondary),
              ),
            ),
          DecoratedBox(
            decoration: ShapeDecoration(
              color: colors.page,
              shape: AppShape.continuous(AppRadius.card),
              shadows: AppShadow.card,
            ),
            child: ClipPath(
              clipper: ShapeBorderClipper(
                shape: AppShape.continuous(AppRadius.card),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int i = 0; i < children.length; i++) ...<Widget>[
                    children[i],
                    if (i != children.length - 1)
                      Divider(
                        height: 0.5,
                        thickness: 0.5,
                        indent: AppSpace.lg,
                        color: colors.divider,
                      ),
                  ],
                ],
              ),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.only(
                left: AppSpace.lg,
                right: AppSpace.lg,
                top: 6,
              ),
              child: Text(
                footer!,
                style: AppText.caption.copyWith(color: colors.secondary),
              ),
            ),
        ],
      ),
    );
  }
}

/// 分组列表里的一行（HarmonyOS 48vp 标准行高）。
///
/// 单行用 [AppSize.row]（48）；需要副标题时把 [height] 设为
/// [AppSize.rowLarge]（64）或传 null 让内容自己撑开。
class AppListRow extends StatelessWidget {
  const AppListRow({
    super.key,
    required this.label,
    this.subtitle,
    this.leading,
    this.value,
    this.trailing,
    this.onTap,
    this.chevron = false,
    this.destructive = false,
    this.height = AppSize.row,
    this.padding = const EdgeInsets.symmetric(horizontal: AppSpace.lg),
  });

  final String label;
  final String? subtitle;
  final Widget? leading;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 行尾是否显示 `>`。iOS 只有「进入下一级」的行才有箭头。
  final bool chevron;
  final bool destructive;

  /// null 表示高度由内容决定（两行/三行文案）。
  final double? height;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Color foreground = destructive ? colors.danger : colors.text;

    Widget content = Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          if (leading != null) ...<Widget>[
            leading!,
            const SizedBox(width: AppSpace.md),
          ],
          Expanded(
            child: subtitle == null
                ? Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppFontSize.body,
                      color: foreground,
                    ),
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppFontSize.body,
                          color: foreground,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppFontSize.caption,
                          color: colors.secondary,
                        ),
                      ),
                    ],
                  ),
          ),
          if (value != null) ...<Widget>[
            const SizedBox(width: AppSpace.md),
            // 值最多占 180dp，超出省略：iOS 设置行也是「左标签可压缩、
            // 右侧值截断」，避免窄屏/长邮箱把行撑破。
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                value!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: AppFontSize.labelLg,
                  color: colors.secondary,
                ),
              ),
            ),
          ],
          if (trailing != null) ...<Widget>[
            const SizedBox(width: AppSpace.sm),
            trailing!,
          ],
          if (chevron) ...<Widget>[
            const SizedBox(width: AppSpace.sm),
            Icon(
              Icons.chevron_right_rounded,
              size: AppIcon.chevron,
              color: colors.tertiary,
            ),
          ],
        ],
      ),
    );

    if (height != null) {
      content = SizedBox(height: height, child: content);
    }

    if (onTap == null) {
      return content;
    }
    return AppPressable(onTap: onTap, child: content);
  }
}
