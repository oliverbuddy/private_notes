import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:super_editor/super_editor.dart';

import '../../theme/app_theme.dart';

/// 自绘光标在 Widget 树里的键，测试用（官方光标宽度 0 已不可见）。
const Key xiaojiCaretKey = ValueKey<String>('xiaoji-caret');

/// 移动端光标（自绘）。
///
/// super_editor 的 Android 光标图层把光标画成「整行行盒」× 2dp：正文
/// 15.5 / 1.7 行高下就是 26 × 2dp —— 比字形高 70%、比 iOS/微信的光标
/// 粗一档（用户反馈「光标高度和字体大小不一致、太粗」）。行盒高度是
/// 排版参数，改字阶会连带改整页节奏，所以这里不动排版，只换光标的画法：
///
///   - 高度：行盒的 75%（正文约 19.5dp，贴近字高 15.5 的 1.25 倍）；
///   - 宽度：1.0dp，圆角端头（国内主流输入类 App 的量级）；
///   - 位置：在行盒里垂直居中，跟随 `DocumentLayout` 的位置查询；
///   - 闪烁：沿用 super_editor 的 [BlinkController] 节奏，编辑时立即全亮。
///
/// 官方 Android 图层通过 `caretWidth: 0` 关掉自己画的光标（见
/// `new_editor_page.dart` 的 overlay 列表），选择手柄、工具条锚点不受影响。
class XiaojiCaretLayer extends DocumentLayoutLayerStatefulWidget {
  const XiaojiCaretLayer({super.key, required this.composer});

  final DocumentComposer composer;

  @override
  DocumentLayoutLayerState<XiaojiCaretLayer, Rect?> createState() =>
      _XiaojiCaretLayerState();
}

class _XiaojiCaretLayerState
    extends DocumentLayoutLayerState<XiaojiCaretLayer, Rect?>
    with SingleTickerProviderStateMixin {
  /// 光标宽度（dp）。
  ///
  /// 用户两轮反馈「偏粗」：1.5 在 2.6x 屏上是 3.9 个物理像素，仍显笨重；
  /// 收到 1.0（约 2.6 物理像素），与微信/iOS 的细光标一致。
  static const double _caretWidth = 1.0;

  /// 光标高度占行盒的比例。
  ///
  /// 正文 26.35 的行盒 → 19.8dp，约为字号的 1.28 倍；标题行盒更高，
  /// 比例截断在 [maxCaretHeight]，避免大标题下光标长得像一条竖线。
  static const double _heightRatio = 0.75;
  static const double maxCaretHeight = 26;

  late final BlinkController _blink;

  @override
  void initState() {
    super.initState();
    _blink = BlinkController(tickerProvider: this);
    widget.composer.selectionNotifier.addListener(_onSelectionChange);
  }

  @override
  void didUpdateWidget(XiaojiCaretLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.composer != oldWidget.composer) {
      oldWidget.composer.selectionNotifier.removeListener(_onSelectionChange);
      widget.composer.selectionNotifier.addListener(_onSelectionChange);
    }
  }

  @override
  void dispose() {
    widget.composer.selectionNotifier.removeListener(_onSelectionChange);
    _blink.dispose();
    super.dispose();
  }

  void _onSelectionChange() {
    // 光标移动/输入时立刻全亮，跟手（官方 Android 光标同款行为）。
    _blink.jumpToOpaque();
    final selection = widget.composer.selection;
    if (selection == null) {
      _blink.stopBlinking();
    } else {
      _blink.startBlinking();
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Rect? computeLayoutDataWithDocumentLayout(
    BuildContext contentLayersContext,
    BuildContext documentContext,
    DocumentLayout documentLayout,
  ) {
    final selection = widget.composer.selection;
    if (selection == null || !selection.isCollapsed) {
      // 展开选区时由选择高亮表达范围，不再画光标。
      return null;
    }
    if (selection.extent.nodePosition is! TextNodePosition) {
      // 块级选中（图片/附件/分隔线）：由选择手柄表达，不画文本光标。
      return null;
    }
    if (documentLayout.getComponentByNodeId(selection.extent.nodeId) == null) {
      return null;
    }

    final Rect? lineRect;
    try {
      lineRect = documentLayout.getRectForPosition(selection.extent);
    } catch (error) {
      // 非文本组件（图片/附件）的光标位置查询会抛异常：这类块有自己的
      // 选中表现，直接不画光标，避免把异常放大成每帧崩溃。
      return null;
    }
    if (lineRect == null || lineRect.height <= 0) {
      return null;
    }

    final double height = math.min(lineRect.height * _heightRatio, maxCaretHeight);
    final double top = lineRect.top + (lineRect.height - height) / 2;
    return Rect.fromLTWH(lineRect.left, top, _caretWidth, height);
  }

  @override
  Widget doBuild(BuildContext context, Rect? caretRect) {
    if (caretRect == null) {
      return const SizedBox.shrink();
    }
    final Color color = AppColors.of(context).accent;
    return IgnorePointer(
      child: Stack(
        children: <Widget>[
          Positioned.fromRect(
            rect: caretRect,
            child: AnimatedBuilder(
              key: xiaojiCaretKey,
              animation: _blink,
              builder: (BuildContext context, Widget? child) {
                return Opacity(
                  opacity: _blink.opacity,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(_caretWidth / 2),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 把自绘光标挂进 SuperEditor 的图层链。
class XiaojiCaretLayerBuilder extends SuperEditorLayerBuilder {
  XiaojiCaretLayerBuilder(this.composer);

  final DocumentComposer composer;

  @override
  ContentLayerWidget build(BuildContext context, SuperEditorContext editContext) {
    return XiaojiCaretLayer(composer: composer);
  }
}
