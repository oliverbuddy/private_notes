import 'dart:async';

import 'package:flutter/material.dart';

Timer? _hideTimer;

/// 统一的底部提示条：自动消失 + 可选操作按钮。
///
/// 不用裸 `SnackBar` 的原因：Flutter 的自动隐藏依赖内部计时器，在无障碍 /
/// UiAutomation 等环境下会停用（`accessibleNavigation` 为 true 时刻意不自动
/// 隐藏），实测会出现「已移到回收站」一直挂在底部不消失。
///
/// 这里显式兜底：普通模式到点主动收起；无障碍模式保留更长阅读时间，
/// 但仍然允许用户点操作按钮或切换页面后关闭。
void showSnack(
  BuildContext context, {
  required String message,
  SnackBarAction? action,
  Duration duration = const Duration(seconds: 4),
}) {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  _hideTimer?.cancel();
  messenger
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        action: action,
        duration: duration,
      ),
    );
  if (!MediaQuery.accessibleNavigationOf(context)) {
    _hideTimer = Timer(duration + const Duration(milliseconds: 300), () {
      // 此刻可能已被用户点「撤销」关闭，或已换成新的提示；
      // 新提示会先 cancel 这个计时器，所以这里只会收起当前这一条。
      messenger.hideCurrentSnackBar();
    });
  }
}

/// 当前页面切走时收起提示条（避免 SnackBar 跟着路由跑到别的页面）。
void hideSnack(BuildContext context) {
  _hideTimer?.cancel();
  _hideTimer = null;
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
}
