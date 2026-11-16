import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

Timer? _hideTimer;

/// 统一的底部提示条：自动消失 + 可选操作按钮。
///
/// 不用裸 `SnackBar` 的自动隐藏：Flutter 在无障碍模式（`accessibleNavigation`
/// 为 true，含 UiAutomation 调试环境）下会刻意停用 SnackBar 自带的计时器，
/// 导致「已移到「回收站」」这类提示一直挂在底部不消失。
///
/// 时长参考主流产品（Gmail / Keep / 微信）：纯告知 1.8 秒足够读完，
/// 只有带「撤销」这类可操作按钮时才给 4 秒决策窗口；无障碍模式仍会
/// 适度延长（纯提示 4 秒、带操作 8 秒），但不会无限挂起。
///
/// 宽度也按内容收窄并居中（最长 360）：纯提醒不该横贯整屏。
void showSnack(
  BuildContext context, {
  required String message,
  SnackBarAction? action,
  Duration? duration,
}) {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final bool accessible = MediaQuery.accessibleNavigationOf(context);
  final Duration base = duration ??
      (action == null
          ? const Duration(milliseconds: 1800)
          : const Duration(seconds: 4));
  final Duration visible = accessible
      ? (action == null
          ? const Duration(seconds: 4)
          : const Duration(seconds: 8))
      : base;

  // 按压测文字宽度收窄提示条：短提示是紧凑胶囊，长提示最多 360 换行。
  final ThemeData theme = Theme.of(context);
  final TextStyle contentStyle = theme.snackBarTheme.contentTextStyle ??
      const TextStyle(fontSize: AppFontSize.label);
  final TextScaler textScaler = MediaQuery.textScalerOf(context);
  final TextDirection textDirection = Directionality.of(context);

  double measureWidth(String text, TextStyle style) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: textDirection,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    return painter.width;
  }

  final double maxWidth = math.min(MediaQuery.sizeOf(context).width - 32, 360);
  // 操作按钮不再用 SnackBarAction：它内部是 TextButton，自带 48 高的点击区
  // （整条提示被撑到 72 高，看起来"内边距很大"），左右还各有一层内边距，
  // 宽度很难量准 —— 少算十几像素，短提示就被挤到换行（用户反馈）。
  // 这里自己排版：正文 + 16 间距 + 操作文字，宽度按同一套样式精确测量。
  final TextStyle? actionStyle = action == null
      ? null
      : contentStyle.copyWith(
          fontWeight: AppWeight.medium,
          color:
              action.textColor ?? theme.snackBarTheme.actionTextColor,
        );
  final double labelWidth = action == null
      ? 0
      : measureWidth(action.label, actionStyle!) + 4;
  final double gap = action == null ? 0 : 16;
  // +2 是亚像素取整余量：TextPainter 量出来是浮点，布局再取整时可能多占 1px。
  final double textWidth = math.max(
    0,
    math.min(
      measureWidth(message, contentStyle) + 2,
      maxWidth - 32 - gap - labelWidth,
    ),
  );
  final double toastWidth = math.max(
    96,
    math.min(textWidth + 32 + gap + labelWidth, maxWidth),
  );

  _hideTimer?.cancel();
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Row(
          children: <Widget>[
            Flexible(child: Text(message)),
            if (action != null) ...<Widget>[
              const SizedBox(width: 16),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                // 与框架的 SnackBarAction 一致：先收起提示，再执行回调。
                onTap: () {
                  _hideTimer?.cancel();
                  messenger.hideCurrentSnackBar();
                  action.onPressed();
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 4,
                  ),
                  child: Text(action.label, style: actionStyle),
                ),
              ),
            ],
          ],
        ),
        duration: visible,
        behavior: SnackBarBehavior.floating,
        width: toastWidth,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ),
    );

  _hideTimer = Timer(visible + const Duration(milliseconds: 300), () {
    // 提示可能已被用户点「撤销」收起，或页面已销毁。
    if (!messenger.mounted) {
      return;
    }
    messenger.hideCurrentSnackBar();
  });
}

/// 当前页面切走时收起提示条（避免 SnackBar 跟着路由跑到别的页面）。
void hideSnack(BuildContext context) {
  _hideTimer?.cancel();
  _hideTimer = null;
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
}
