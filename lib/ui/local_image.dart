import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// 本地图片加载工具。
///
/// 方案选择：小记的图片全部在本地，不需要 `cached_network_image` 这类
/// 网络缓存插件；Flutter 自带的 `Image` + `ResizeImage`（即 `Image.file`
/// 的 `cacheWidth` / `cacheHeight`）就是官方推荐的本地图片路径。
/// 这里只补两件官方 API 没直接给的事：
///  1. 统一按「显示尺寸 × devicePixelRatio」换算解码尺寸，缩略图不再
///     把整张 4000px 原图解码进内存；
///  2. 用 `ImageDescriptor` 只解析文件头拿原始像素尺寸，避免为了算
///     宽高比而把整张大图完整解码一遍。
final Map<String, Size> _pixelSizeCache = <String, Size>{};

/// 读取本地图片的原始像素尺寸（只解析文件头，不解码像素）。
///
/// 结果缓存最近 [maxEntries] 张；文件丢失或格式不支持时返回 null，
/// 由调用方回落到占位比例。
Future<Size?> readLocalImagePixelSize(
  String path, {
  int maxEntries = 128,
}) async {
  final Size? cached = _pixelSizeCache[path];
  if (cached != null) {
    return cached;
  }
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromFilePath(path);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final double width = descriptor.width.toDouble();
    final double height = descriptor.height.toDouble();
    if (width <= 0 || height <= 0) {
      return null;
    }
    final Size size = Size(width, height);
    if (_pixelSizeCache.length >= maxEntries &&
        !_pixelSizeCache.containsKey(path)) {
      _pixelSizeCache.remove(_pixelSizeCache.keys.first);
    }
    _pixelSizeCache[path] = size;
    return size;
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// 把逻辑显示尺寸换算成图片解码用的物理像素尺寸。
///
/// [max] 限制解码上限（缩略图 1024、详情页 1440 足够肉眼清晰）；
/// 结果按 8 像素对齐，避免布局取整的细小差异让 ImageCache 反复重建。
int localImageDecodeExtent(
  BuildContext context,
  double logicalSize, {
  int min = 32,
  int max = 2048,
}) {
  final double dpr = MediaQuery.devicePixelRatioOf(context);
  final int raw = (logicalSize * (dpr > 0 ? dpr : 1)).ceil();
  final int clamped = raw.clamp(min, max);
  return ((clamped + 7) ~/ 8) * 8;
}
