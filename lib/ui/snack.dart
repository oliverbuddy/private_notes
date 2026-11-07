import 'dart:async';

import 'package:flutter/material.dart';

Timer? _hideTimer;

/// 统一的底部提示条：自动消失 + 可选操作按钮。
///
/// 不用裸 `SnackBar` 的自动隐藏：Flutter 在无障碍模式（`accessibleNavigation`
/// 为 true，含 UiAutomation 调试环境）下会刻意停用 SnackBar 自带的计时器，
/// 导致「已移到「回收站」」这类提示一直挂在底部不消失。
///
/// 主流产品（Gmail / Keep / 微信）的撤销提示都是 4~5 秒后自动收起，只留
/// 一次撤销窗口。这里统一用显式计时器兜底：普通模式 4 秒；无障碍模式把
/// 阅读时间延长到 10 秒，但仍然会收起，不再常驻。
void showSnack(
  BuildContext context, {
  required String message,
  SnackBarAction? action,
  Duration duration = const Duration(seconds: 4),
}) {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final bool accessible = MediaQuery.accessibleNavigationOf(context);
  final Duration visible = accessible ? const Duration(seconds: 10) : duration;

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
