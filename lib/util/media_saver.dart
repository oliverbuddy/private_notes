import 'dart:async';

import 'package:flutter/services.dart';

/// 把图片保存到系统相册（Android MediaStore）。
///
/// 走原生 MethodChannel，不引入第三方相册插件：
///  - Android 10+：写入 `Pictures/小记`，不需要存储权限；
///  - Android 9 及以下：退到应用专属目录（不需要权限），但不在系统相册里。
///
/// 返回 true 表示已进入系统相册；false 表示只保存到了应用目录。
Future<bool> saveImageToGallery(String absolutePath) async {
  final Map<Object?, Object?>? result =
      await const MethodChannel('xiaoji/native').invokeMethod<Map<Object?, Object?>>(
    'saveImage',
    <String, Object?>{'path': absolutePath},
  );
  return result?['savedToGallery'] == true;
}

/// 调起系统分享面板，把本地图片分享到其他 App。
///
/// 原生侧用 FileProvider 生成 `content://` 授权 URI，不需要存储权限，
/// 也不引入第三方分享插件。
Future<void> shareImageFile(String absolutePath) async {
  await const MethodChannel('xiaoji/native').invokeMethod<void>(
    'shareImage',
    <String, Object?>{'path': absolutePath},
  );
}
