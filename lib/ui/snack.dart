import 'dart:async';

import 'package:flutter/material.dart';

Timer? _hideTimer;

/// 统一的底部提示条：自动消失 + 可选操作按钮。
///
/// 不用裸 `SnackBar` 的自动隐藏：Flutter 在无障碍模式（`accessibleNavigation`
/// 为 true，含 UiAutomation 调试环境）下会刻意停用 SnackBar 自带的计时器，
/// 导致「已移到「回收站」」这类提示一直挂在底部不消失。
///
/// 主流产品（Gmail / Keep / 微信）的提示时长：纯告知类 2 秒足够读完，
/// 只有带「撤销」这类可操作按钮时才需要 4~5 秒的决策窗口。
/// 无障碍模式把阅读时间延长（纯提示 6 秒、带操作 10 秒），但仍然会收起。
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
          ? const Duration(seconds: 2)
          : const Duration(seconds: 4));
  final Duration visible = accessible
      ? (action == null ? const Duration(seconds: 6) : const Duration(seconds: 10))
      : base;

  _hideTimer?.cancel();
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        action: action,
        duration: visible,
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
