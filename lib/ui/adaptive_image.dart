import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'local_image.dart';

/// 微信式图片框：先按原比例缩放，只有「极端长图」才裁切并打「长图」角标。
///
/// 微信 / 主流 IM 的图片规则（这里按同一套实现）：
///  1. **不放大**：原图小于目标宽度时按原始逻辑尺寸显示，避免小图被拉糊；
///  2. **先缩后裁**：高度超过上限时，先整体缩小，让整张图装进上限；
///     只有缩完会窄成一条（超长截图）时才改为「定宽 + 裁切」；
///  3. **裁切有提示**：被裁切的图右下角标「长图」，点开查看器看完整原图。
///
/// 宽高比通过 [readLocalImagePixelSize] 只解析文件头获得，不再为了拿
/// 尺寸把整张原图解码进内存。
class AdaptiveImageFrame extends StatefulWidget {
  const AdaptiveImageFrame({
    super.key,
    required this.path,
    required this.child,
    this.widthFactor = 1,
    this.maxHeight = 420,
  });

  /// 原图绝对路径（用来解析宽高比与原始像素宽度）。
  final String path;

  /// 由调用方传入的图片组件（保留 ImageComponent 的 componentKey，
  /// 查看器的放大动画仍从这块渲染盒子飞出来）。
  final Widget child;

  /// 目标宽度占可用宽度的比例（小图 0.4 / 大图 1.0）。
  final double widthFactor;

  /// 展示高度上限（dp）；超过则先缩后裁，见类注释。
  final double maxHeight;

  @override
  State<AdaptiveImageFrame> createState() => _AdaptiveImageFrameState();
}

class _AdaptiveImageFrameState extends State<AdaptiveImageFrame> {
  /// 原图原始像素尺寸；null 表示还在解析。
  Size? _pixelSize;

  /// 解析失败（文件丢失 / 格式不支持）：按 4:3 兜底，交给图片组件的
  /// errorBuilder 显示占位。
  bool _failed = false;

  /// 异步解析的请求序号：切图或销毁后丢弃旧结果。
  int _sizeRequest = 0;

  @override
  void initState() {
    super.initState();
    _loadPixelSize();
  }

  @override
  void didUpdateWidget(AdaptiveImageFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _pixelSize = null;
      _failed = false;
      _loadPixelSize();
    }
  }

  Future<void> _loadPixelSize() async {
    final int request = ++_sizeRequest;
    final Size? size = await readLocalImagePixelSize(widget.path);
    if (!mounted || request != _sizeRequest) {
      return;
    }
    setState(() {
      if (size == null) {
        _failed = true;
      } else {
        _pixelSize = size;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double targetWidth = constraints.maxWidth * widget.widthFactor;
        final Size? pixel = _pixelSize;

        // 尺寸没解析出来前先给一个稳定占位，避免图片加载时正文跳动。
        if (pixel == null && !_failed) {
          return Align(
            alignment: Alignment.centerLeft,
            child: Container(
              width: targetWidth,
              height: math.min(targetWidth * 0.75, widget.maxHeight),
              decoration: BoxDecoration(
                color: colors.surface2,
                borderRadius: BorderRadius.circular(AppRadius.block),
              ),
            ),
          );
        }

        final double aspect =
            pixel == null ? 4 / 3 : pixel.width / math.max(1, pixel.height);
        final double dpr = MediaQuery.devicePixelRatioOf(context);
        // 原图的逻辑宽度（像素宽 / devicePixelRatio），用于「不放大」。
        final double naturalWidth = pixel == null
            ? targetWidth
            : pixel.width / (dpr > 0 ? dpr : 1);

        // 规则 1：不放大。原图逻辑宽度更小就按原尺寸显示。
        double width = math.min(targetWidth, naturalWidth);
        double height = width / aspect;
        // 裁切阈值以「目标宽度」为基准，横图补宽后不再回头影响竖图判断。
        final double baseWidth = width;
        bool cropped = false;

        // 规则 1.5：宽幅横图（全景/长条截图）在「小图」下不能压成一条
        // 几十像素的细线 —— 太细既看不清也不好点。按最小可读高度
        // （44dp）补足宽度，但不超过通栏与原图宽度。
        const double minReadableHeight = 44;
        if (height < minReadableHeight) {
          final double neededWidth = minReadableHeight * aspect;
          final double maxWidth = math.min(constraints.maxWidth, naturalWidth);
          width = math.min(neededWidth, maxWidth);
          height = width / aspect;
        }

        // 规则 2：先按比例算整图高度；超限时先尝试整体缩小。
        final double naturalHeight = width / aspect;
        if (naturalHeight > widget.maxHeight) {
          final double fitWidth = widget.maxHeight * aspect;
          // 缩小后仍保有可读宽度（≥ 目标宽的一半）→ 整图显示、不裁切。
          // 普通竖图（3:4、9:16）走的都是这一支。
          if (fitWidth >= baseWidth * 0.5) {
            width = fitWidth;
            height = widget.maxHeight;
          } else {
            // 规则 3：超长截图（缩完只剩一条）才定宽裁切 + 「长图」角标。
            height = widget.maxHeight;
            cropped = true;
          }
        }

        return Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: width,
            height: height,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.block),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  widget.child,
                  if (cropped)
                    const Positioned(
                      right: 8,
                      bottom: 8,
                      // 角标只是提示，不能吃掉图片的点击/长按。
                      child: IgnorePointer(child: _LongImageBadge()),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 「长图」角标：提示这张图在正文里是裁切预览，点开能看完整长图。
class _LongImageBadge extends StatelessWidget {
  const _LongImageBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.open_in_full_rounded, size: AppIcon.badge, color: Colors.white),
          SizedBox(width: 3),
          Text(
            '长图',
            style: TextStyle(
              fontSize: AppFontSize.micro,
              height: 1,
              color: Colors.white,
              fontWeight: AppWeight.medium,
            ),
          ),
        ],
      ),
    );
  }
}
