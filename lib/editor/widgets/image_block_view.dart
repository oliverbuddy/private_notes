import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../../ui/show_sheet.dart';
import '../block.dart';

/// 图片块：宽度撑满、圆角 8、按原始宽高比自适应。
///
/// 用 `Image.file` + `BoxFit.fitWidth` 让高度由图片自身比例决定 ——
/// 这样不同尺寸的截图混排时不会被裁切，也不会出现巨大留白。
class ImageBlockView extends StatelessWidget {
  const ImageBlockView({
    super.key,
    required this.block,
    required this.absolutePath,
    required this.onTap,
    required this.onLongPress,
  });

  final ImageBlock block;

  /// 已经解析成绝对路径的文件位置。
  final String absolutePath;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        GestureDetector(
          onTap: onTap,
          onLongPress: onLongPress,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.block),
            child: Image.file(
              File(absolutePath),
              width: double.infinity,
              fit: BoxFit.fitWidth,
              // 文件被用户在「文件」App 里删掉时不能崩，给一个占位。
              errorBuilder: (context, error, stackTrace) => Container(
                height: 150,
                width: double.infinity,
                alignment: Alignment.center,
                color: colors.surface2,
                child: Text(
                  '图片已丢失',
                  style: TextStyle(fontSize: 12, color: colors.tertiary),
                ),
              ),
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                if (wasSynchronouslyLoaded || frame != null) {
                  return child;
                }
                return Container(
                  height: 150,
                  width: double.infinity,
                  color: colors.surface2,
                );
              },
            ),
          ),
        ),
        if (block.alt.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              block.alt.trim(),
              style: TextStyle(fontSize: 11, color: colors.secondary),
            ),
          ),
      ],
    );
  }
}

/// 全屏看图（手势对齐国内大图查看器，参考微信大图）。
///
/// - 单击：顶栏（关闭按钮 + 图片说明）200ms 淡入淡出切换。
/// - 双击：在 1x / 2.5x 之间切换，以双击点为中心，200ms 动画；
///   双击点贴近屏幕边缘时平移量会被夹住（内容贴边，不露白）。
/// - 双指捏合：[InteractiveViewer]，1x ~ 4x；放大后单指拖动由它接管平移。
/// - 拖动关闭：仅当处于 1x 时启用。单指在**任意方向**拖动，图片 1:1
///   跟手位移、按离原点的距离等比缩小（最多 25%），背景同步淡出 ——
///   与微信大图的「图随手走」一致；松手时竖直位移超过 120px 或竖直
///   速度够快直接 pop，否则 200ms 回弹。拖动期间顶栏隐藏，回弹后恢复。
/// - 长按：底部确认弹层提供「删除图片」，确认后 pop 回编辑页并回调删块。
///
/// 手势归属：[InteractiveViewer] 内部就是一个 ScaleGestureRecognizer。
/// 外层再挂 GestureDetector 的 pan 会和它在同一阈值（36px）上抢竞技场，
/// 内层胜出后 pan 永远收不到事件（实测竖直拖 90px 也是 0 位移）。所以
/// 拖动统一由 `onInteraction*` 回调驱动——它和缩放手势同源，不会互抢。
/// 按下位置用 `Listener` 记录（原始指针事件不参与竞技场），把识别前被
/// 吃掉的滑移补回来，保证「图随手走」不漏前 36px。
///
/// 出入场由 [buildImageViewerRoute] 的飞行转场负责：本页背景与图片
/// 透明度跟随路由动画（0 = 全透明，把画面让给飞行图层）。
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.absolutePath,
    required this.dragOffset,
    this.dragScale,
    this.alt = '',
    this.onDelete,
  });

  final String absolutePath;

  /// 下滑关闭的跟手位移，实时同步给路由的飞行图层：
  /// 松手 pop 时图片从「拖到的位置」飞回缩略图，而不是跳回全屏。
  final ValueNotifier<Offset> dragOffset;

  /// 下滑关闭时同步的轻微缩小比例（微信大图下滑时图片会略缩），
  /// 退场飞行图层的终点也要按它收缩，避免 pop 瞬间图片跳大。
  final ValueNotifier<double>? dragScale;

  final String alt;

  /// 在查看器里确认删除后调用（此时查看器已 pop，编辑页负责删块）。
  final VoidCallback? onDelete;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage>
    // 两个 AnimationController（双击缩放 + 下滑回弹），必须用可提供多个
    // ticker 的 mixin —— SingleTickerProviderStateMixin 在第一次双击时
    // 直接抛「multiple tickers were created」，debug 包双击放大必崩。
    with
        TickerProviderStateMixin {
  /// 下滑关闭：位移超过 120px、或松手速度超过 700px/s。
  static const double _dismissDistance = 120;
  static const double _dismissSpeed = 700;

  /// 双击最大缩放。
  static const double _doubleTapScale = 2.5;

  /// 拖动满这个像素距离，背景从 1 渐变到 0.5。
  static const double _backdropFadeSpan = 300;

  final TransformationController _transform = TransformationController();
  late final AnimationController _zoomController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  late final AnimationController _settleController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

  Animation<Matrix4>? _zoomAnim;
  Animation<double>? _settleAnim;
  Offset _settleBegin = Offset.zero;
  double _settleBeginScale = 1.0;

  /// 拖动关闭的跟手位移（任意方向 1:1，与微信大图一致）。
  Offset _dragOffset = Offset.zero;

  /// 拖动时图片的轻微缩小（1 → 0.75），微信大图同款手感。
  double _dragScale = 1.0;

  bool _topBarVisible = true;
  bool _barWasVisible = true;

  /// scale > 1 时为 true：此时单指拖动交给 InteractiveViewer 平移。
  bool _isZoomed = false;

  /// 单指拖动关闭是否进行中。1x 按下即进入；双指或缩放态不进入。
  bool _dismissing = false;

  /// 上一帧焦点（跟手量 = 本帧焦点 - 上一帧焦点）。
  Offset? _lastFocalPoint;

  /// 原始按下位置。ScaleGestureRecognizer 要吃掉 36px 滑移才认手，
  /// 用按下点当拖动起点，第一帧就把这段滑移补回来（图随手走不漏帧）。
  Offset? _pointerDownPosition;

  Offset? _doubleTapPosition;
  Size _viewportSize = Size.zero;

  /// 图片像素尺寸。双击缩放的边界要按「图片 contain 之后在屏幕上的矩形」
  /// 算，而不是按整屏算 —— 否则宽高比不一致时会把图挪出边界、露出一块黑。
  Size? _imageSize;
  ImageProvider? _provider;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransformChanged);
    _settleController.addStatusListener(_onSettleStatus);
    final FileImage provider = FileImage(File(widget.absolutePath));
    _provider = provider;
    _listener = ImageStreamListener(_onImageInfo, onError: (_, __) {});
    _stream = provider.resolve(ImageConfiguration.empty)
      ..addListener(_listener!);
  }

  void _onImageInfo(ImageInfo info, bool synchronousCall) {
    final Size size = Size(
      info.image.width.toDouble(),
      info.image.height.toDouble(),
    );
    info.dispose();
    if (!mounted || size == _imageSize) {
      return;
    }
    setState(() => _imageSize = size);
  }

  @override
  void dispose() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _transform.removeListener(_onTransformChanged);
    _zoomController.stop();
    _settleController.stop();
    _transform.dispose();
    _zoomController.dispose();
    _settleController.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.005;
    if (zoomed != _isZoomed) {
      setState(() => _isZoomed = zoomed);
    }
  }

  void _onSettleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) {
      return;
    }
    if (mounted) {
      setState(() => _topBarVisible = _barWasVisible);
    }
  }

  // ---- 单击：顶栏显隐 ----

  void _toggleTopBar() {
    setState(() => _topBarVisible = !_topBarVisible);
  }

  // ---- 双击：1x / 2.5x 切换，以双击点为中心 ----

  void _handleDoubleTap() {
    final position = _doubleTapPosition ?? _viewportSize.center(Offset.zero);
    final currentScale = _transform.value.getMaxScaleOnAxis();
    final Matrix4 target;
    if (currentScale > 1.005) {
      target = Matrix4.identity();
    } else {
      target = _zoomMatrixAt(position, _doubleTapScale);
    }
    _animateTransform(target);
  }

  /// 图片按 contain 铺到视口后，在视口坐标系里占的矩形。
  Rect _contentRect() {
    final Size viewport = _viewportSize;
    final Size? image = _imageSize;
    if (image == null ||
        image.isEmpty ||
        viewport.isEmpty ||
        !viewport.width.isFinite ||
        !viewport.height.isFinite) {
      return Offset.zero & viewport;
    }
    final double scale = math.min(
      viewport.width / image.width,
      viewport.height / image.height,
    );
    return Rect.fromCenter(
      center: viewport.center(Offset.zero),
      width: image.width * scale,
      height: image.height * scale,
    );
  }

  /// 把 [point]（视口坐标，1x 时等于子坐标）作为缩放中心的变换矩阵。
  ///
  /// 平移量按「图片 contain 后的矩形仍然盖住视口」夹住：图片比视口小的
  /// 方向居中，比视口大的方向贴边，双击点靠边时内容贴边而不是露出空白
  /// —— 与微信大图一致。
  Matrix4 _zoomMatrixAt(Offset point, double scale) {
    final Matrix4 m = Matrix4.identity()
      ..translateByDouble(point.dx, point.dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-point.dx, -point.dy, 0, 1);

    final Rect content = _contentRect();
    final double tx = m.storage[12];
    final double ty = m.storage[13];
    final Rect scaled = Rect.fromLTRB(
      content.left * scale + tx,
      content.top * scale + ty,
      content.right * scale + tx,
      content.bottom * scale + ty,
    );

    double dx = 0;
    if (scaled.width <= _viewportSize.width) {
      dx = (_viewportSize.width - scaled.width) / 2 - scaled.left;
    } else if (scaled.left > 0) {
      dx = -scaled.left;
    } else if (scaled.right < _viewportSize.width) {
      dx = _viewportSize.width - scaled.right;
    }

    double dy = 0;
    if (scaled.height <= _viewportSize.height) {
      dy = (_viewportSize.height - scaled.height) / 2 - scaled.top;
    } else if (scaled.top > 0) {
      dy = -scaled.top;
    } else if (scaled.bottom < _viewportSize.height) {
      dy = _viewportSize.height - scaled.bottom;
    }

    m.setTranslationRaw(tx + dx, ty + dy, 0);
    return m;
  }

  void _animateTransform(Matrix4 target) {
    _zoomController.stop();
    _zoomAnim?.removeListener(_onZoomTick);
    _zoomAnim = Matrix4Tween(
      begin: _transform.value.clone(),
      end: target,
    ).animate(
      CurvedAnimation(parent: _zoomController, curve: Curves.easeOutCubic),
    )..addListener(_onZoomTick);
    _zoomController.forward(from: 0);
  }

  void _onZoomTick() {
    final value = _zoomAnim?.value;
    if (value != null) {
      _transform.value = value;
    }
  }

  // ---- 单指拖动关闭（1x 时启用手势，缩放态交给 InteractiveViewer） ----

  /// 记录原始按下位置（Listener 不参与竞技场，一定收得到）。
  void _handlePointerDown(PointerDownEvent event) {
    _pointerDownPosition = event.localPosition;
  }

  /// InteractiveViewer 手势开始：1x 单指进入拖动关闭，双指/缩放态不进入。
  void _handleInteractionStart(ScaleStartDetails details) {
    // 正在回弹时重新按下：停在当前位移继续跟手。
    _settleController.stop();
    // 识别前的滑移补回来：起点用真实按下点，而不是识别成功那一刻的焦点。
    _lastFocalPoint = _pointerDownPosition ?? details.localFocalPoint;
    if (_isZoomed || details.pointerCount > 1) {
      _dismissing = false;
      return;
    }
    _dismissing = true;
    _barWasVisible = _topBarVisible;
    if (_topBarVisible) {
      setState(() => _topBarVisible = false);
    }
  }

  void _handleInteractionUpdate(ScaleUpdateDetails details) {
    // 双指捏合中途加入：拖到一半的画面必须先归位，否则缩放和位移叠加，
    // 松手后图片会「停在一个莫名其妙的位置」。
    if (_dismissing && details.pointerCount > 1) {
      _dismissing = false;
      _lastFocalPoint = details.localFocalPoint;
      _settleBack();
      return;
    }
    if (!_dismissing) {
      _lastFocalPoint = details.localFocalPoint;
      return;
    }
    final Offset previous = _lastFocalPoint ?? details.localFocalPoint;
    _lastFocalPoint = details.localFocalPoint;
    final Offset delta = details.localFocalPoint - previous;
    if (delta == Offset.zero) {
      return;
    }
    setState(() {
      _dragOffset += delta;
      final double progress =
          (_dragOffset.distance / _backdropFadeSpan).clamp(0.0, 1.0);
      _dragScale = 1 - progress * 0.25;
    });
    // 同步给路由的飞行图层：松手 pop 时从当前位置/比例飞回缩略图。
    widget.dragOffset.value = _dragOffset;
    widget.dragScale?.value = _dragScale;
  }

  void _handleInteractionEnd(ScaleEndDetails details) {
    if (!_dismissing) {
      return;
    }
    _dismissing = false;
    // 只按**竖直**判定关闭：横向拖是「随便挪一下」，不该误关。
    final double vertical = _dragOffset.dy.abs();
    final double verticalSpeed = details.velocity.pixelsPerSecond.dy.abs();
    if (vertical > _dismissDistance || verticalSpeed > _dismissSpeed) {
      // 位移已经在手上，直接 pop，不叠加默认的反向动画。
      Navigator.of(context).pop();
      return;
    }
    _settleBack();
  }

  void _settleBack() {
    _settleController.stop();
    _settleAnim?.removeListener(_onSettleTick);
    _settleBegin = _dragOffset;
    _settleBeginScale = _dragScale;
    _settleAnim = Tween<double>(begin: 0, end: 1)
        .chain(CurveTween(curve: Curves.easeOutCubic))
        .animate(_settleController)
      ..addListener(_onSettleTick);
    _settleController.forward(from: 0);
  }

  void _onSettleTick() {
    final t = _settleAnim?.value;
    if (t == null || !mounted) {
      return;
    }
    setState(() {
      _dragOffset =
          Offset(_settleBegin.dx * (1 - t), _settleBegin.dy * (1 - t));
      _dragScale = _settleBeginScale + (1 - _settleBeginScale) * t;
    });
    widget.dragOffset.value = _dragOffset;
    widget.dragScale?.value = _dragScale;
  }

  // ---- 长按：删除入口 ----

  Future<void> _confirmDelete() async {
    final bool? confirmed = await showXiaojiConfirmSheet(
      context: context,
      title: '删除图片',
      message: '删除后正文里将不再显示这张图片。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (confirmed != true || !mounted) {
      return;
    }
    Navigator.of(context).pop();
    widget.onDelete?.call();
  }

  @override
  Widget build(BuildContext context) {
    final double progress =
        (_dragOffset.distance / _backdropFadeSpan).clamp(0.0, 1.0);
    // 下滑时背景一路淡到接近透明（不是只淡到 50%），图片同时轻微缩小，
    // 松手到阈值后画面已经「退到后面」，pop 不会显得突兀 —— 微信大图同款。
    final double dragFade = 1.0 - progress * 0.85;
    // 路由动画（0→1）：飞行转场期间本页整体透明，把画面让给飞行图层；
    // 转场结束后本页不透明，拖动淡出照常由 dragFade 控制。
    final Animation<double>? routeAnimation = ModalRoute.of(context)?.animation;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // 图片查看页是黑底，状态栏必须用白色图标；否则浅色主题下
      // 继承主页的深色图标，在黑底上几乎看不见（用户反馈的细节问题）。
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: AnimatedBuilder(
          animation: routeAnimation ?? kAlwaysCompleteAnimation,
          builder: (BuildContext context, Widget? _) {
            final double routeOpacity = routeAnimation?.value ?? 1.0;
            return ColoredBox(
              color: Colors.black.withValues(alpha: routeOpacity * dragFade),
              child: Opacity(
                opacity: routeOpacity,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggleTopBar,
                  onDoubleTapDown: (details) =>
                      _doubleTapPosition = details.localPosition,
                  onDoubleTap: _handleDoubleTap,
                  onLongPress: _confirmDelete,
                  // 拖动不在这里接：PanGestureRecognizer 和 InteractiveViewer
                  // 内的 ScaleGestureRecognizer 同阈值抢竞技场必输（详见类注释）。
                  child: Listener(
                    onPointerDown: _handlePointerDown,
                    child: Stack(
                      children: <Widget>[
                        Transform.translate(
                          offset: _dragOffset,
                          child: Transform.scale(
                            scale: _dragScale,
                            child: LayoutBuilder(
                              builder: (BuildContext context,
                                  BoxConstraints constraints) {
                                // 视口必须是整屏：之前 Image 放在 Center 里按自身
                                // 尺寸参与布局，InteractiveViewer 的视口就只有图片
                                // 那么大 —— 双击放大后图片会被这块小视口裁掉一部分
                                // （用户实测「放大后不能全屏展示」）。
                                final Size viewport = Size(
                                  constraints.maxWidth.isFinite
                                      ? constraints.maxWidth
                                      : MediaQuery.sizeOf(context).width,
                                  constraints.maxHeight.isFinite
                                      ? constraints.maxHeight
                                      : MediaQuery.sizeOf(context).height,
                                );
                                _viewportSize = viewport;
                                return InteractiveViewer(
                                  transformationController: _transform,
                                  minScale: 1,
                                  maxScale: 4,
                                  // 拖动 / 捏合都由它的手势驱动：它内部的
                                  // ScaleGestureRecognizer 就是竞技场赢家，
                                  // 外面再接 pan 只会拿到 0 事件。
                                  onInteractionStart: _handleInteractionStart,
                                  onInteractionUpdate: _handleInteractionUpdate,
                                  onInteractionEnd: _handleInteractionEnd,
                                  child: SizedBox(
                                    width: viewport.width,
                                    height: viewport.height,
                                    child: _provider == null
                                        ? const SizedBox.shrink()
                                        : Image(
                                            image: _provider!,
                                            fit: BoxFit.contain,
                                            errorBuilder:
                                                (context, error, stackTrace) =>
                                                    const Center(
                                              child: Text(
                                                '图片已丢失',
                                                style: TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ),
                                          ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: SafeArea(
                            bottom: false,
                            child: AnimatedOpacity(
                              opacity: _topBarVisible ? 1 : 0,
                              duration: const Duration(milliseconds: 200),
                              child: IgnorePointer(
                                ignoring: !_topBarVisible,
                                child: Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(4, 4, 16, 0),
                                  child: Row(
                                    children: <Widget>[
                                      IconButton(
                                        onPressed: () =>
                                            Navigator.of(context).maybePop(),
                                        icon: const Icon(
                                          Icons.close,
                                          color: Colors.white,
                                          size: 22,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          widget.alt.trim(),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: Colors.white
                                                .withValues(alpha: 0.85),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 微信式图片查看路由：从缩略图位置展开 / 收回。
///
/// - 进场：黑色背景淡入，图片从缩略图的全局矩形飞到全屏 contain 位置，
///   圆角从 8 过渡到 0；转场结束后飞行图层撤掉，手势交还查看器。
/// - 退场：反向飞回缩略图（编辑页 opaque:false 保持挂载，缩略图矩形
///   随时有效）；下滑关闭时从松手位置继续飞回（[dragOffset] 同步）。
Route<void> buildImageViewerRoute({
  required Rect sourceRect,
  required String absolutePath,
  String alt = '',
  VoidCallback? onDelete,
}) {
  final ValueNotifier<Offset> dragOffset = ValueNotifier<Offset>(Offset.zero);
  final ValueNotifier<double> dragScale = ValueNotifier<double>(1.0);
  return PageRouteBuilder<void>(
    opaque: false,
    transitionDuration: const Duration(milliseconds: 300),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
    ) {
      return ImageViewerPage(
        absolutePath: absolutePath,
        alt: alt,
        onDelete: onDelete,
        dragOffset: dragOffset,
        dragScale: dragScale,
      );
    },
    transitionsBuilder: (
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child,
    ) {
      return _FlightTransition(
        animation: animation,
        sourceRect: sourceRect,
        dragOffset: dragOffset,
        dragScale: dragScale,
        absolutePath: absolutePath,
        child: child,
      );
    },
  );
}

/// 飞行图层：转场期间在缩略图矩形 ↔ 全屏之间插值展示同一张图片，
/// 圆角同步收拢。转场完成即撤掉（不挡查看器的手势），退场开始再挂回来。
class _FlightTransition extends StatefulWidget {
  const _FlightTransition({
    required this.animation,
    required this.sourceRect,
    required this.dragOffset,
    required this.dragScale,
    required this.absolutePath,
    required this.child,
  });

  final Animation<double> animation;
  final Rect sourceRect;
  final ValueNotifier<Offset> dragOffset;
  final ValueNotifier<double> dragScale;
  final String absolutePath;
  final Widget child;

  @override
  State<_FlightTransition> createState() => _FlightTransitionState();
}

class _FlightTransitionState extends State<_FlightTransition> {
  bool _flightDone = false;

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(_FlightTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_onStatus);
      widget.animation.addStatusListener(_onStatus);
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && !_flightDone) {
      setState(() => _flightDone = true);
    } else if (status == AnimationStatus.reverse && _flightDone) {
      setState(() => _flightDone = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Size screenSize = MediaQuery.sizeOf(context);
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (BuildContext context, Widget? _) {
        final Widget backdrop = ColoredBox(
          color: Colors.black.withValues(alpha: widget.animation.value),
          child: widget.child,
        );
        if (_flightDone) {
          return backdrop;
        }
        final double t = Curves.easeOutCubic.transform(widget.animation.value);
        // 终点按「拖动位移 + 拖动缩小比例」计算：下滑松手时飞行图层的
        // 起始尺寸必须和手指上的图片一致，否则 pop 那一帧会突然变大。
        final double scale = widget.dragScale.value;
        final Rect target = Rect.fromCenter(
          center: (Offset.zero & screenSize).center + widget.dragOffset.value,
          width: screenSize.width * scale,
          height: screenSize.height * scale,
        );
        final Rect rect =
            Rect.lerp(widget.sourceRect, target, t) ?? widget.sourceRect;
        final double radius = lerpDouble(AppRadius.block, 0, t)!;
        return Stack(
          children: <Widget>[
            Positioned.fill(child: backdrop),
            Positioned.fromRect(
              rect: rect,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: Image.file(
                  File(widget.absolutePath),
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
