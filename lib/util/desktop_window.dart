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

/// 同步窗口顶栏（标题栏）底色与应用页面底色。
///
/// macOS 的标题栏默认是系统灰，与应用页面（浅色纯白 / 深色近黑）并排
/// 时明显是两套风格（用户反馈「顶部状态栏和应用没有保持一致」）。
/// 这里把标题栏改成透明、窗口底色设成页面色，标题栏就「融进」应用。
/// 主题切换时由 [XiaojiApp] 重新调用一次；Windows 暂不处理。
Future<void> syncDesktopWindowChrome(Color pageColor) async {
  if (!PlatformFeatures.isMacOS) {
    return;
  }
  try {
    await _channel.invokeMethod<bool>('setWindowChrome', <String, dynamic>{
      'color': pageColor.toARGB32(),
      'dark': pageColor.computeLuminance() < 0.5,
    });
  } catch (error) {
    debugPrint('同步窗口顶栏失败: $error');
  }
}
