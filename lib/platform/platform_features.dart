import 'package:flutter/foundation.dart';

/// 平台能力探测。
///
/// 业务层只问「这个平台有没有这个能力」，不要在各处直接写
/// `Platform.isAndroid` —— 目前只有 Android 实现，iOS / PC 后续接入时
/// 在这里补一条判断即可，界面会自动隐藏或降级，不会把系统调用打挂。
abstract final class PlatformFeatures {
  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 能否接收其他 App 的分享（Android ACTION_SEND）。
  /// iOS 对应 Share Extension，桌面端对应「打开文件 / 拖拽」。
  static bool get canReceiveShare => isAndroid;

  /// 是否提供桌面小组件 / 快捷磁贴这类系统入口。
  static bool get hasSystemWidgets => isAndroid;
}
