import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
/// 对外分享时在长图底部追加一行极简落款（App 图标 + 「小记 · 日期」），
/// 不修改正文宽度、不打断阅读。日期取笔记的最后更新时间。
Future<void> shareNoteAsImage({
  required RenderObject documentLayout,
  required Color background,
  DateTime? updatedAt,
}) async {
  final Uint8List bytes = await renderDocumentShareImage(
    documentLayout: documentLayout,
    background: background,
    updatedAt: updatedAt,
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

/// 落款区域的版式：正文上留 24、落款与正文间隔 20、落款行高 16、底部留 24。
/// 只在上下加留白，不改正文宽度，避免换行位置与详情不一致。
const double _shareTopPadding = 24;
const double _shareFooterGap = 20;
const double _shareFooterHeight = 16;
const double _shareBottomPadding = 24;
const double _shareFooterExtra = _shareTopPadding +
    _shareFooterGap +
    _shareFooterHeight +
    _shareBottomPadding;

/// 把文档布局的绘制结果渲染成 PNG 字节（不落盘、不分享，便于测试）。
///
/// 用 `PaintingContext` 直接把渲染对象画进独立的 `OffsetLayer`，再对该层
/// `toImage`：这样不受可视区域/滚动裁剪影响，整篇内容（含滚到屏外的部分）
/// 都会出现在图里。最后把正文图与落款合成到同一张画布，保证落款始终在
/// 图片最底部、且在超长内容下也不会挤压正文。
Future<Uint8List> renderDocumentShareImage({
  required RenderObject documentLayout,
  required Color background,
  DateTime? updatedAt,
}) async {
  final RenderBox box = _resolveDocumentBox(documentLayout);
  final Size size = box.size;
  if (size.isEmpty) {
    throw StateError('图片生成失败：内容为空');
  }

  final double totalHeight = size.height + _shareFooterExtra;
  final double ratio = math.min(
    math.max(1, _targetWidthPx / size.width),
    // 超长内容降倍率，避免超出常见 GPU 纹理上限导致整张图失败。
    math.max(0.5, 8192 / totalHeight),
  );

  final OffsetLayer layer = OffsetLayer();
  final PaintingContext context = PaintingContext(layer, Offset.zero & size);
  // 纸面底色由这里补：文档布局本身是透明的，只画文字/组件。
  context.canvas.drawRect(Offset.zero & size, Paint()..color = background);
  box.paint(context, Offset.zero);
  // 把当前正在录制的 Picture 落到 layer 上，否则 toImage 拿到的是空层。
  // ignore: invalid_use_of_protected_member
  context.stopRecordingIfNeeded();

  ui.Image? contentImage;
  ui.Image? brandIcon;
  try {
    contentImage = await layer.toImage(Offset.zero & size, pixelRatio: ratio);
    // 图标读不到时落款退化为纯文字，不能因此让分享失败。
    brandIcon = await _loadBrandIcon();

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    canvas.scale(ratio);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, totalHeight),
      Paint()..color = background,
    );
    canvas.drawImageRect(
      contentImage,
      Rect.fromLTWH(
        0,
        0,
        contentImage.width.toDouble(),
        contentImage.height.toDouble(),
      ),
      Rect.fromLTWH(0, _shareTopPadding, size.width, size.height),
      Paint()..filterQuality = FilterQuality.medium,
    );
    _paintFooter(
      canvas,
      contentWidth: size.width,
      background: background,
      icon: brandIcon,
      updatedAt: updatedAt ?? DateTime.now(),
      footerTop: _shareTopPadding + size.height + _shareFooterGap,
    );

    final ui.Picture picture = recorder.endRecording();
    final ui.Image output = await picture.toImage(
      (size.width * ratio).round(),
      (totalHeight * ratio).round(),
    );
    picture.dispose();
    try {
      final ByteData? data =
          await output.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw StateError('图片编码失败');
      }
      return data.buffer.asUint8List();
    } finally {
      output.dispose();
    }
  } finally {
    contentImage?.dispose();
    brandIcon?.dispose();
  }
}

/// 画底部落款：`[小记图标] 小记 · 2026.11.16`，整体居中。
///
/// 颜色由纸面明暗推导（深色纸面用浅字），不依赖页面主题，保证分享图
/// 在浅色/深色两种纸面上都安静、可读。
void _paintFooter(
  Canvas canvas, {
  required double contentWidth,
  required Color background,
  required ui.Image? icon,
  required DateTime updatedAt,
  required double footerTop,
}) {
  final bool dark = background.computeLuminance() < 0.5;
  final Color brandColor =
      dark ? const Color(0xB3FFFFFF) : const Color(0x73000000);
  final Color dateColor =
      dark ? const Color(0x80FFFFFF) : const Color(0x59000000);

  final TextStyle brandStyle = TextStyle(
    fontSize: 12,
    height: 1.2,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.2,
    color: brandColor,
  );
  final TextStyle dateStyle = TextStyle(
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.2,
    color: dateColor,
  );
  final TextPainter text = TextPainter(
    text: TextSpan(
      children: <TextSpan>[
        TextSpan(text: '小记', style: brandStyle),
        TextSpan(text: '  ·  ', style: dateStyle),
        TextSpan(text: _formatShareDate(updatedAt), style: dateStyle),
      ],
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  const double iconSize = 14;
  const double iconGap = 6;
  final double totalWidth =
      (icon == null ? 0 : iconSize + iconGap) + text.width;
  double x = (contentWidth - totalWidth) / 2;
  final double centerY = footerTop + _shareFooterHeight / 2;

  if (icon != null) {
    final Rect iconRect = Rect.fromLTWH(
      x,
      centerY - iconSize / 2,
      iconSize,
      iconSize,
    );
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(iconRect, const Radius.circular(4)),
    );
    canvas.drawImageRect(
      icon,
      Rect.fromLTWH(0, 0, icon.width.toDouble(), icon.height.toDouble()),
      iconRect,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
    x += iconSize + iconGap;
  }
  text.paint(canvas, Offset(x, centerY - text.height / 2));
  text.dispose();
}

String _formatShareDate(DateTime date) {
  final String month = date.month.toString().padLeft(2, '0');
  final String day = date.day.toString().padLeft(2, '0');
  return '${date.year}.$month.$day';
}

/// 读取 App 图标作为落款标记；任何失败都返回 null（落款退化为纯文字）。
Future<ui.Image?> _loadBrandIcon() async {
  try {
    final ByteData data = await rootBundle.load('assets/app_icon.png');
    final ui.Codec codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(),
      targetWidth: 64,
    );
    final ui.FrameInfo frame = await codec.getNextFrame();
    return frame.image;
  } catch (_) {
    return null;
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
