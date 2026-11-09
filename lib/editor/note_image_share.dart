import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/note_store.dart';
import '../theme/app_theme.dart';
import '../ui/tag_chip.dart';
import '../util/media_saver.dart';
import 'lab/image_display_size.dart';
import 'markdown_view.dart';

/// 把当前笔记渲染成一张分享长图，并调起系统分享面板。
///
/// 只依赖 Flutter 自身的离屏渲染 + 原生 FileProvider，不引入第三方分享插件：
///  - 内容取自编辑器的**实时文档**（未落盘的改动也会出现在图里）；
///  - 分享图固定浅色纸面（与 App 日间主题一致），不受用户深色模式影响；
///  - 图片按 2x 输出（540 逻辑宽 → 1080px），超长笔记自动降倍率避免
///    超出 GPU 纹理上限。
///
/// 失败时抛出异常，由调用方决定提示文案。
Future<void> shareNoteAsImage({
  required String markdown,
  required List<String> tags,
  required DateTime created,
  required NoteStore store,
}) async {
  String resolveImagePath(String url) => _absoluteImagePath(store, url);
  final Uint8List bytes = await renderNoteShareImagePng(
    markdown: markdown,
    tags: tags,
    created: created,
    resolveImagePath: resolveImagePath,
  );

  final Directory dir = await getTemporaryDirectory();
  final File file = File(
    p.join(
      dir.path,
      'xiaoji-share-${DateTime.now().millisecondsSinceEpoch}.png',
    ),
  );
  await file.writeAsBytes(bytes, flush: true);
  // 缓存目录里只留最近几次分享图，避免长期使用越堆越多。
  await _cleanupOldShareImages(dir);
  await shareImageFile(file.path);
}

/// 生成分享长图的 PNG 字节（不落盘、不分享，便于测试与复用）。
Future<Uint8List> renderNoteShareImagePng({
  required String markdown,
  required List<String> tags,
  required DateTime created,
  required String Function(String url) resolveImagePath,
  double width = _cardWidth,
}) async {
  final List<_ShareBlock> blocks = _splitBlocks(markdown);

  // 图片必须先解码进 ImageCache：离屏渲染只跑一帧，没解码完就是空白。
  for (final _ShareBlock block in blocks) {
    if (block is _ShareImageBlock) {
      await _precacheImage(resolveImagePath(block.url));
    }
  }

  final Widget card = _NoteShareCard(
    blocks: blocks,
    tags: tags,
    created: created,
    resolveImagePath: resolveImagePath,
    width: width,
  );
  return _renderToPng(card, width: width);
}

/// 删除一天前的分享图缓存（同一目录下只由本功能写入 `xiaoji-share-*.png`）。
Future<void> _cleanupOldShareImages(Directory dir) async {
  try {
    final DateTime deadline =
        DateTime.now().subtract(const Duration(days: 1));
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

/// 分享图逻辑宽度：2x 输出正好 1080px，主流分享图尺寸。
const double _cardWidth = 540;

/// 离屏渲染倍率。
const double _capturePixelRatio = 2;

/// 分享图的内容块：连续正文段 / 单独一行的图片。
sealed class _ShareBlock {
  const _ShareBlock();
}

class _ShareTextBlock extends _ShareBlock {
  const _ShareTextBlock(this.text);

  final String text;
}

class _ShareImageBlock extends _ShareBlock {
  const _ShareImageBlock(this.url);

  final String url;
}

/// 独占一行的图片：`![alt](assets/…)`，允许结尾带显示尺寸标记。
final RegExp _imageLine = RegExp(r'^\s*!\[[^\]]*\]\(([^)\s]+)\)\s*$');

/// 围栏行：用于跳过代码块内部的「图片行」，避免把代码当图片。
final RegExp _fenceLine = RegExp(r'^\s*[`~]{3,}');

/// 按「图片块 / 正文块」切分正文，代码围栏内的内容原样留在正文块里。
List<_ShareBlock> _splitBlocks(String markdown) {
  final List<_ShareBlock> blocks = <_ShareBlock>[];
  final StringBuffer buffer = StringBuffer();
  bool inFence = false;

  void flushText() {
    final String text = buffer.toString().trimRight();
    buffer.clear();
    if (text.trim().isNotEmpty) {
      blocks.add(_ShareTextBlock(text));
    }
  }

  for (final String line in markdown.split('\n')) {
    if (_fenceLine.hasMatch(line)) {
      inFence = !inFence;
      buffer.writeln(line);
      continue;
    }
    final RegExpMatch? image = inFence ? null : _imageLine.firstMatch(line);
    if (image == null) {
      buffer.writeln(line);
      continue;
    }
    flushText();
    blocks.add(_ShareImageBlock(image.group(1)!));
  }
  flushText();
  return blocks;
}

String _absoluteImagePath(NoteStore store, String url) {
  final String raw = imageFilePath(url);
  return raw.startsWith('assets/') ? store.absoluteAssetPath(raw) : raw;
}

/// 把图片解码进缓存，保证离屏渲染的那一帧能同步画出来。
Future<void> _precacheImage(String path) async {
  final File file = File(path);
  if (!file.existsSync()) {
    return;
  }
  final ImageStream stream = FileImage(file).resolve(ImageConfiguration.empty);
  final Completer<void> completer = Completer<void>();
  void finish() {
    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (ImageInfo _, bool __) => finish(),
    onError: (Object _, StackTrace? __) => finish(),
  );
  stream.addListener(listener);
  try {
    // 解码失败/超大图也不能卡住分享：最多等 3 秒就继续。
    await completer.future.timeout(const Duration(seconds: 3), onTimeout: finish);
  } finally {
    stream.removeListener(listener);
  }
}

/// 离屏渲染：单独建一棵 RenderView 树，layout + paint 后从 RepaintBoundary
/// 取像素。不依赖页面可见区域，因此整篇笔记（含滚动到屏外的内容）都在图里。
Future<Uint8List> _renderToPng(
  Widget widget, {
  required double width,
}) async {
  // RepaintBoundary 必须真的挂在离屏树里，才能从它的 layer 取像素；
  // 它就是 RenderView 的直接子节点，直接从渲染树取，避免依赖 GlobalKey。
  final PipelineOwner pipelineOwner = PipelineOwner();
  final BuildOwner buildOwner = BuildOwner(focusManager: FocusManager());
  final RenderView renderView = RenderView(
    view: WidgetsBinding.instance.platformDispatcher.views.first,
    configuration: ViewConfiguration(
      // 宽度固定，高度由内容撑开（RenderView 在约束不紧时取子节点尺寸）。
      logicalConstraints: BoxConstraints.tightFor(width: width),
      devicePixelRatio: 1,
    ),
  );
  pipelineOwner.rootNode = renderView;
  renderView.prepareInitialFrame();

  RenderObjectToWidgetAdapter<RenderBox>(
    container: renderView,
    debugShortDescription: '[note-share-image]',
    child: RepaintBoundary(
      child: MediaQuery(
        // 固定 1x 与不缩放：分享图尺寸必须与用户系统字体缩放无关。
        data: const MediaQueryData(
          devicePixelRatio: 1,
          textScaler: TextScaler.noScaling,
        ),
        child: Theme(
          data: AppTheme.light(),
          child: Material(
            color: AppColors.light.page,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: widget,
            ),
          ),
        ),
      ),
    ),
  ).attachToRenderTree(buildOwner);

  buildOwner.finalizeTree();
  pipelineOwner.flushLayout();
  pipelineOwner.flushCompositingBits();
  pipelineOwner.flushPaint();

  final RenderObject? rootChild = renderView.child;
  if (rootChild is! RenderRepaintBoundary || !rootChild.hasSize) {
    throw StateError('图片生成失败：离屏渲染未完成');
  }
  final RenderRepaintBoundary boundary = rootChild;
  final double logicalHeight = boundary.size.height;
  if (logicalHeight <= 0) {
    throw StateError('图片生成失败：内容为空');
  }
  // 超出常见 GPU 纹理上限时降倍率，宁可略糊也不要整张图失败。
  final double ratio = math.min(
    _capturePixelRatio,
    math.max(0.5, 8192 / logicalHeight),
  );

  final ui.Image image = await boundary.toImage(pixelRatio: ratio);
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

/// 分享卡片本体（浅色纸面）。
class _NoteShareCard extends StatelessWidget {
  const _NoteShareCard({
    required this.blocks,
    required this.tags,
    required this.created,
    required this.resolveImagePath,
    required this.width,
  });

  final List<_ShareBlock> blocks;
  final List<String> tags;
  final DateTime created;
  final String Function(String url) resolveImagePath;
  final double width;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Container(
      width: width,
      color: colors.page,
      padding: const EdgeInsets.fromLTRB(32, 32, 32, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            _formatShareDate(created),
            style: TextStyle(
              fontSize: AppFontSize.caption,
              height: 1.2,
              letterSpacing: 0.2,
              color: colors.tertiary,
            ),
          ),
          const SizedBox(height: 20),
          ..._buildBody(context),
          if (tags.isNotEmpty) ...<Widget>[
            const SizedBox(height: 24),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final String tag in tags) TagChip(label: tag),
              ],
            ),
          ],
          const SizedBox(height: 28),
          Container(height: 0.5, color: colors.divider),
          const SizedBox(height: 12),
          Center(
            child: Text(
              '来自「小记」',
              style: TextStyle(
                fontSize: AppFontSize.micro,
                height: 1.2,
                letterSpacing: 0.4,
                color: colors.tertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildBody(BuildContext context) {
    final List<Widget> children = <Widget>[];
    for (final _ShareBlock block in blocks) {
      switch (block) {
        case _ShareTextBlock(:final String text):
          if (children.isNotEmpty) {
            children.add(const SizedBox(height: 12));
          }
          children.add(
            MarkdownBlockView(text: text, baseSize: AppFontSize.summary),
          );
        case _ShareImageBlock(:final String url):
          final String path = resolveImagePath(url);
          if (!File(path).existsSync()) {
            continue;
          }
          if (children.isNotEmpty) {
            children.add(const SizedBox(height: 12));
          }
          final bool small = imageDisplaySizeOf(url) == ImageDisplaySize.small;
          children.add(
            Align(
              alignment: Alignment.centerLeft,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.thumb),
                child: Image.file(
                  File(path),
                  width: small ? width * 0.5 : double.infinity,
                  fit: BoxFit.fitWidth,
                  // 图片坏了就整块跳过，不能留一个碎图标在分享图里。
                  errorBuilder: (BuildContext _, Object __, StackTrace? ___) =>
                      const SizedBox.shrink(),
                ),
              ),
            ),
          );
      }
    }
    return children;
  }
}

/// 分享图上的日期：绝对日期，避免「今天/昨天」在转发后失效。
String _formatShareDate(DateTime time) {
  final DateTime t = time.toLocal();
  return '${t.year}年${t.month}月${t.day}日';
}
