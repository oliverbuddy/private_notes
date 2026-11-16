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
  // SnackBarAction 内部是 TextButton：最小宽度 64、左右各 8 内边距，与正文
  // 之间还有 8 的间距。之前只按「文字宽 + 32」估，宽度少了几像素，左侧
  // 文案会被挤到换行（用户反馈「撤销弹窗文字不多却换行」）。
  final double actionWidth = action == null
      ? 0
      : math.max(
            64,
            measureWidth(
                  action.label,
                  contentStyle.copyWith(fontWeight: AppWeight.medium),
                ) +
                24,
          ) +
          8;
  // +2 是亚像素取整余量：TextPainter 量出来是浮点，布局再取整时可能多占 1px。
  final double textWidth = math.max(
    0,
    math.min(
      measureWidth(message, contentStyle) + 2,
      maxWidth - 32 - actionWidth,
    ),
  );
  final double toastWidth =
      math.max(96, math.min(textWidth + 32 + actionWidth, maxWidth));

  _hideTimer?.cancel();
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        action: action,
        duration: visible,
        behavior: SnackBarBehavior.floating,
        width: toastWidth,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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
