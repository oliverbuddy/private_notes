import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/platform_features.dart';

const MethodChannel _channel = MethodChannel('xiaoji/native');

/// 切换桌面窗口全屏。
///
/// macOS 走系统原生全屏（与绿色交通灯一致，菜单栏自动隐藏）；
/// Windows 走无边框覆盖当前显示器，退出时恢复原窗口样式与位置。
/// 移动端没有窗口概念，直接忽略。
Future<void> toggleDesktopFullscreen() async {
  if (!PlatformFeatures.isDesktop) {
    return;
  }
  try {
    await _channel.invokeMethod<bool>('toggleFullscreen');
  } catch (error) {
    // 全屏失败不影响编辑：只记日志，不打断用户。
    debugPrint('切换全屏失败: $error');
  }
}
