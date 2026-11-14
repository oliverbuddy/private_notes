import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/platform_features.dart';

const MethodChannel _channel = MethodChannel('xiaoji/native');

/// 桌面端：把本地文件「拖出」到 Finder / 资源管理器。
///
/// Flutter 自身只有应用内的 Draggable/DragTarget，跨应用拖拽必须走原生：
/// macOS 用 `NSDraggingSession`，Windows 用 `IDropSource`。这里只负责把
/// 文件路径与当前指针位置交给原生层，失败返回 false（调用方无需提示）。
Future<bool> beginFileDrag({
  required List<String> paths,
  required Offset position,
}) async {
  if (!PlatformFeatures.isDesktop || paths.isEmpty) {
    return false;
  }
  try {
    final bool? started = await _channel.invokeMethod<bool>(
      'beginFileDrag',
      <String, dynamic>{
        'paths': paths,
        'x': position.dx,
        'y': position.dy,
      },
    );
    return started ?? false;
  } catch (error) {
    debugPrint('拖出文件失败: $error');
    return false;
  }
}
