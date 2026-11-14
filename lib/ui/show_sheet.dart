import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'pressable.dart';

/// 全站统一的底部弹层入口。
///
/// 之前各页面的弹层（菜单、确认框、选项面板）一半是 [AlertDialog]，
/// 一半是各自手画 grabber 的 `showModalBottomSheet`，动画时长也各写各的。
/// 这里把它们收拢：grabber、底色、safe area、进出场时长与曲线都只定义一次，
/// 调用方只负责弹层的内容本身。
///
/// 动画说明：动画时长与曲线全部交给 [AnimationStyle]，由
/// `showModalBottomSheet` 内部自己创建并管理控制器 —— 不要再自建
/// [AnimationController] 传 `transitionAnimationController`。
///
/// 教训（2026-10 线上阻塞 bug）：曾用自定义 vsync 里裸 `Ticker(onTick)`
/// 给控制器供帧。裸 Ticker 创建后是 muted 状态，没有任何人调 `unmute`，
/// 于是 controller 永远停在 0 —— 进场动画从不播放，pop 的 reverse 也
/// 永不推进，弹层关不掉、卡死在屏幕上。除非自己实现 TickerProvider 并
/// 处理 muted 生命周期，否则一律把动画交给框架管理。
Future<T?> showXiaojiSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  // 平板/桌面：弹层不再铺满整屏，按手机宽度收窄并居中。
  // 弹层内容是「一列文字 + 两个按钮」，拉成 1000+ 宽后按钮会变成
  // 两条超长横条，阅读和点击都很别扭。
  final bool wide =
      !AppBreakpoints.isCompact(MediaQuery.sizeOf(context).width);
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: AppColors.of(context).page,
    useSafeArea: true,
    isScrollControlled: true,
    constraints: wide ? const BoxConstraints(maxWidth: 560) : null,
    sheetAnimationStyle: const AnimationStyle(
      duration: AppMotion.normal,
      reverseDuration: AppMotion.normal,
      curve: AppMotion.decelerate,
      reverseCurve: AppMotion.accelerate,
    ),
    builder: (BuildContext sheetContext) {
      final AppColors colors = AppColors.of(sheetContext);
      // grabber 画在统一入口里：各调用点不用再自己画一遍。
      // SizedBox(width: infinity) 让弹层恒与屏幕同宽：bottom sheet 的宽度
      // 约束是 loose 的，内容全是 Text/Wrap 这类 shrink-wrap 组件时
      // （如标签筛选）弹层会缩成一小条浮在中间。
      //
      // grabber 必须用 Center 包住：Column 是 stretch 对齐，会把子项的
      // width: 32 覆盖成整屏宽 —— 32x4 的抓手变成一条通栏灰线
      // （用户实测抓到过）。stretch 只影响 Column 的直接子项，
      // Center 的 child 拿到的是 loose 约束，宽度得以保留。
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Center(
            child: Container(
              // iOS 抓手：36 × 5，圆角 2.5。
              width: 36,
              height: 5,
              margin: const EdgeInsets.only(top: 6, bottom: 8),
              decoration: BoxDecoration(
                color: colors.text.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
          ),
          // 内容区必须拿到「剩余高度」这个**有限**约束：Column 的普通子项
          // 在主轴上是无限高度约束，内容一旦比屏幕高（小屏 + 键盘弹出）
          // 就只能溢出，内部的滚动区也拿不到高度、无法滚动。
          // 用 Flexible 让内容拿到 剩余空间，内容没超高时尺寸与之前完全一致。
          Flexible(
            child:
                SizedBox(width: double.infinity, child: builder(sheetContext)),
          ),
        ],
      );
    },
  );
}

/// 统一的确认弹层（原 AlertDialog 的替代品）。
///
/// 危险操作（删除）用实心红按钮，是国内 App 的惯例；普通确认（移除附件）
/// 用 accent 文字。两个按钮等宽、52 高、圆角 10，横向并排铺满。
Future<bool?> showXiaojiConfirmSheet({
  required BuildContext context,
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) {
  return showXiaojiSheet<bool>(
    context: context,
    builder: (BuildContext sheetContext) {
      final AppColors colors = AppColors.of(sheetContext);
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: AppText.sheetTitle.copyWith(color: colors.text),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                style: TextStyle(
                  fontSize: AppFontSize.labelLg,
                  height: 1.5,
                  color: colors.secondary,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: <Widget>[
                  Expanded(
                    child: AppSheetButton(
                      label: '取消',
                      background: colors.surface2,
                      foreground: colors.secondary,
                      onTap: () => Navigator.of(sheetContext).pop(false),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AppSheetButton(
                      label: confirmLabel,
                      background: destructive ? colors.danger : colors.surface2,
                      foreground:
                          destructive ? colors.onDanger : colors.accent,
                      onTap: () => Navigator.of(sheetContext).pop(true),
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
}

/// 弹层里的并排按钮：鸿蒙 40 高、20 连续圆角、16 Medium。
///
/// 确认、标签、链接、附件、重命名等所有弹层共用这一份，避免各写一套
/// 高度/圆角/字号（以前出现过 48 高 + 8 圆角 + 14 字号的例外）。
class AppSheetButton extends StatelessWidget {
  const AppSheetButton({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  final String label;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppPressable(
      onTap: onTap,
      pressedScale: 0.98,
      child: Container(
        height: AppSize.button,
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: background,
          shape: AppShape.continuous(AppRadius.button),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppFontSize.body,
            height: 1,
            fontWeight: AppWeight.medium,
            color: foreground,
          ),
        ),
      ),
    );
  }
}
