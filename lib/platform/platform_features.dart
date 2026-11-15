import 'package:flutter/foundation.dart';

/// 平台能力探测。
///
/// 业务层只问「这个平台有没有这个能力」，不要在各处直接写
/// `Platform.isAndroid` —— 界面据此自动隐藏或降级，不会把系统调用打挂。
abstract final class PlatformFeatures {
  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 能否接收其他 App 的分享（Android ACTION_SEND）。
  static bool get canReceiveShare => isAndroid;
}
