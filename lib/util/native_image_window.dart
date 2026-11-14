import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/platform_features.dart';

const MethodChannel _channel = MethodChannel('xiaoji/native');

/// 桌面端：用**独立窗口**打开图片预览。
///
/// 参考主流桌面应用（Finder 预览 / 系统「预览」App）：双击图片是单独一个
/// 可缩放、可关闭的窗口，而不是把图片放大铺在应用内部。小记只有在原生
/// 窗口不可用时才回退到应用内查看器。
///
/// 返回 true 表示已由原生窗口接管。
Future<bool> openImageInNativeWindow({
  required String path,
  String title = '',
}) async {
  if (!PlatformFeatures.isDesktop) {
    return false;
  }
  try {
    final bool? opened = await _channel.invokeMethod<bool>(
      'previewImage',
      <String, dynamic>{'path': path, 'title': title},
    );
    return opened ?? false;
  } catch (error) {
    debugPrint('打开图片窗口失败，回退应用内查看: $error');
    return false;
  }
}
