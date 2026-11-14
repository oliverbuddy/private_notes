import 'package:flutter/foundation.dart';

/// 平台能力探测。
///
/// 业务层只问「这个平台有没有这个能力」，不要在各处直接写
/// `Platform.isAndroid` —— 界面据此自动隐藏或降级，不会把系统调用打挂。
abstract final class PlatformFeatures {
  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 桌面端（macOS / Windows / Linux）。
  ///
  /// 桌面与移动端的差异不只是窗口大小：没有系统分享、没有桌面小组件，
  /// 快捷键和鼠标右键才是主要交互。凡是「移动端专属入口」都要用它判断。
  static bool get isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  static bool get isMacOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static bool get isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// 能否接收其他 App 的分享（Android ACTION_SEND）。
  /// iOS 对应 Share Extension，桌面端对应「打开文件 / 拖拽」。
  static bool get canReceiveShare => isAndroid;

  /// 是否提供桌面小组件 / 快捷磁贴这类系统入口。
  static bool get hasSystemWidgets => isAndroid;
}
