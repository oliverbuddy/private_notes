import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../util/media_saver.dart';

/// 把详情页的内容生成整篇长图并调起系统分享。
///
/// 直接复刻详情页**当前的真实渲染结果**，而不是把 Markdown 用另一套组件再画
/// 一遍。因此：
///  - 宽度就是详情内容列宽，每行字数、换行位置与详情完全一致；
///  - 表格、代码块卡片、引用、图片、行内样式就是详情里的同一批组件；
///  - 深色模式下分享图保持用户看到的深色纸面。
///
/// [documentLayout] 传 super_editor 的文档布局渲染对象（只包含正文内容，
/// 不含光标/选区浮层）。失败时抛出异常，由调用方决定提示文案。
Future<void> shareNoteAsImage({
  required RenderObject documentLayout,
  required Color background,
}) async {
  final Uint8List bytes = await renderDocumentShareImage(
    documentLayout: documentLayout,
    background: background,
  );

  final Directory dir = await getTemporaryDirectory();
  final File file = File(
    p.join(
      dir.path,
      'xiaoji-share-${DateTime.now().millisecondsSinceEpoch}.png',
    ),
  );
  await file.writeAsBytes(bytes, flush: true);
  // 缓存目录里只留最近一天的分享图，避免长期使用越堆越多。
  await _cleanupOldShareImages(dir);
  await shareImageFile(file.path);
}

/// 输出图片的目标宽度（像素），主流分享图的清晰度。
const double _targetWidthPx = 1080;

/// 把文档布局的绘制结果渲染成 PNG 字节（不落盘、不分享，便于测试）。
///
/// 用 `PaintingContext` 直接把渲染对象画进独立的 `OffsetLayer`，再对该层
/// `toImage`：这样不受可视区域/滚动裁剪影响，整篇内容（含滚到屏外的部分）
/// 都会出现在图里。
Future<Uint8List> renderDocumentShareImage({
  required RenderObject documentLayout,
  required Color background,
}) async {
  final RenderBox box = _resolveDocumentBox(documentLayout);
  final Size size = box.size;
  if (size.isEmpty) {
    throw StateError('图片生成失败：内容为空');
  }

  final double ratio = math.min(
    math.max(1, _targetWidthPx / size.width),
    // 超长内容降倍率，避免超出常见 GPU 纹理上限导致整张图失败。
    math.max(0.5, 8192 / size.height),
  );

  final OffsetLayer layer = OffsetLayer();
  final PaintingContext context = PaintingContext(layer, Offset.zero & size);
  // 纸面底色由这里补：文档布局本身是透明的，只画文字/组件。
  context.canvas.drawRect(Offset.zero & size, Paint()..color = background);
  box.paint(context, Offset.zero);
  // 把当前正在录制的 Picture 落到 layer 上，否则 toImage 拿到的是空层。
  // ignore: invalid_use_of_protected_member
  context.stopRecordingIfNeeded();

  final ui.Image image = await layer.toImage(
    Offset.zero & size,
    pixelRatio: ratio,
  );
  try {
    final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) {
      throw StateError('图片编码失败');
    }
    return data.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// 取出真正承载内容的 RenderBox。
///
/// super_editor 的文档布局放在滚动视图里时会被包一层 `SliverToBoxAdapter`，
/// 此时 `documentLayoutKey.findRenderObject()` 拿到的是 sliver，真正的内容
/// 盒子是它的 child。没有滚动容器时本身就是 RenderBox。
RenderBox _resolveDocumentBox(RenderObject documentLayout) {
  if (documentLayout is RenderSliverSingleBoxAdapter) {
    final RenderBox? child = documentLayout.child;
    if (child != null && child.hasSize) {
      return child;
    }
  }
  if (documentLayout is RenderBox && documentLayout.hasSize) {
    return documentLayout;
  }
  throw StateError('图片生成失败：内容还没完成布局');
}

/// 删除一天前的分享图缓存（同一目录下只由本功能写入 `xiaoji-share-*.png`）。
Future<void> _cleanupOldShareImages(Directory dir) async {
  try {
    final DateTime deadline = DateTime.now().subtract(const Duration(days: 1));
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is! File ||
          !p.basename(entity.path).startsWith('xiaoji-share-')) {
        continue;
      }
      if (entity.statSync().modified.isBefore(deadline)) {
        await entity.delete();
      }
    }
  } catch (_) {
    // 清理失败不影响分享本身。
  }
}
