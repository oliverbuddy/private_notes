import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'pressable.dart';

/// 桌面右键 / 长按 / 顶栏菜单里的一项。
class DesktopMenuEntry<T> {
  const DesktopMenuEntry({
    required this.label,
    required this.value,
    this.enabled = true,
    this.destructive = false,
    this.dividerBefore = false,
    this.icon,
    this.indent = 0,
    this.selected = false,
    this.muted = false,
    this.strong = false,
  });

  final String label;
  final T value;
  final bool enabled;
  final bool destructive;

  /// 在这一项之前画一条分隔线（分组用）。
  final bool dividerBefore;

  /// 可选图标（顶栏菜单用）。
  final IconData? icon;

  /// 左缩进（目录按标题层级缩进）。
  final double indent;

  /// 当前生效项：右侧显示对勾。
  final bool selected;

  /// 次级文字色（目录的二级 / 三级标题）。
  final bool muted;

  /// 主色加粗（目录的一级标题）。
  final bool strong;
}

/// 桌面菜单：直接插入 Overlay，不 push 路由。
///
/// 为什么不用 `showMenu`：它会 push 一条路由并接管焦点，
/// SuperEditor 在焦点变化时会收起选区 —— 用户看到的正是「右键后蓝色选中底
/// 消失」。Overlay 方案不改变焦点，因此选区、光标、滚动位置都保持原样。
///
/// 视觉与交互和顶栏「⋯」共用同一份实现：同样的 8 圆角、0.5 描边、投影、
/// 40 行高、150ms 淡入缩放动画；[anchor] 给出时贴按钮下沿右对齐，
/// 否则贴住 [globalPosition]（右键 / 长按）。
Future<T?> showDesktopMenu<T>({
  required BuildContext context,
  required List<DesktopMenuEntry<T>> entries,
  Offset? globalPosition,
  Rect? anchor,
  String? header,
  double maxWidth = 260,
}) {
  final OverlayState overlay = Overlay.of(context, rootOverlay: true);
  final Completer<T?> completer = Completer<T?>();
  late final OverlayEntry overlayEntry;
  late final bool Function(KeyEvent event) handleKey;

  void close([T? value]) {
    if (completer.isCompleted) {
      return;
    }
    overlayEntry.remove();
    HardwareKeyboard.instance.removeHandler(handleKey);
    completer.complete(value);
  }

  handleKey = (KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      close();
      return true;
    }
    return false;
  };

  overlayEntry = OverlayEntry(
    builder: (BuildContext overlayContext) {
      final AppColors colors = AppColors.of(overlayContext);
      final Size screen = MediaQuery.sizeOf(overlayContext);
      // Material 必须有：没有 Material 祖先的 Text 会被 Flutter 画上
      // 一条黄色双下划线（用户反馈「文字底部有黄线」就是它）。
      final Widget panel = Material(
        color: Colors.transparent,
        child: ConstrainedBox(
          // 宽度按内容自适应，只封顶不垫底：短菜单（复制/剪切）不会被
          // 撑成一条宽横条。
          constraints: BoxConstraints(
            maxWidth: maxWidth,
            maxHeight: screen.height * 0.6,
          ),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: colors.page,
              borderRadius: BorderRadius.circular(AppRadius.block),
              border: Border.all(color: colors.chipBorder, width: 0.5),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.22),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (header != null && header.isNotEmpty) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
                      child: Text(
                        header,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppFontSize.caption,
                          color: colors.tertiary,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Divider(
                        height: 0.5,
                        thickness: 0.5,
                        color: colors.divider,
                      ),
                    ),
                  ],
                  for (final DesktopMenuEntry<T> entry in entries) ...<Widget>[
                    if (entry.dividerBefore)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Divider(
                          height: 0.5,
                          thickness: 0.5,
                          color: colors.divider,
                        ),
                      ),
                    _DesktopMenuRow<T>(
                      entry: entry,
                      onTap: () => close(entry.value),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );

      // 与系统菜单一致的进场：150ms 淡入 + 轻微缩放（从贴边的一侧展开）。
      final Widget animatedPanel = TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        builder: (BuildContext context, double t, Widget? child) {
          return Opacity(
            opacity: t,
            child: Transform.scale(
              scale: 0.96 + 0.04 * t,
              alignment: anchor != null ? Alignment.topRight : Alignment.topLeft,
              child: child,
            ),
          );
        },
        child: panel,
      );

      final Rect? anchorRect = anchor;
      return Stack(
        children: <Widget>[
          // 透明遮罩：点空白关闭（可见的仍然是原来的选区与正文）。
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => close(),
              child: const SizedBox.expand(),
            ),
          ),
          if (anchorRect != null)
            Positioned(
              right: (screen.width - anchorRect.right).clamp(0.0, screen.width),
              top: (anchorRect.bottom + 4).clamp(0.0, screen.height),
              child: animatedPanel,
            )
          else
            _positionedAtPointer(
              screen: screen,
              position: globalPosition ?? Offset.zero,
              child: animatedPanel,
            ),
        ],
      );
    },
  );

  overlay.insert(overlayEntry);
  HardwareKeyboard.instance.addHandler(handleKey);
  return completer.future;
}

/// 贴住鼠标位置，越界时回收到屏幕内。
Widget _positionedAtPointer({
  required Size screen,
  required Offset position,
  required Widget child,
}) {
  // 宽度是内容自适应的，这里按最小宽度估算即可；越界时整体回收进屏幕。
  const double estimateWidth = 160;
  final double left = position.dx + estimateWidth > screen.width - 8
      ? (screen.width - estimateWidth - 8).clamp(8.0, screen.width)
      : position.dx.clamp(0.0, screen.width - estimateWidth);
  final double top = position.dy.clamp(8.0, screen.height);
  return Positioned(left: left, top: top, child: child);
}

class _DesktopMenuRow<T> extends StatelessWidget {
  const _DesktopMenuRow({
    required this.entry,
    required this.onTap,
  });

  final DesktopMenuEntry<T> entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Color foreground = entry.enabled
        ? (entry.destructive
            ? colors.danger
            : entry.muted
                ? colors.secondary
                : colors.text)
        : colors.tertiary;
    return AppPressable(
      enabled: entry.enabled,
      onTap: entry.enabled ? onTap : null,
      pressedScale: 1,
      pressedColor: AppPress.overlay(context),
      child: SizedBox(
        height: 40,
        child: Padding(
          padding: EdgeInsets.only(left: 14 + entry.indent, right: 14),
          child: Row(
            children: <Widget>[
              if (entry.icon != null) ...<Widget>[
                Icon(entry.icon, size: AppIcon.compact, color: foreground),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Text(
                  entry.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: entry.strong
                        ? AppFontSize.body
                        : AppFontSize.labelLg,
                    fontWeight:
                        entry.strong ? AppWeight.medium : AppWeight.regular,
                    color: foreground,
                  ),
                ),
              ),
              if (entry.selected) ...<Widget>[
                const SizedBox(width: 10),
                Icon(
                  Icons.check_rounded,
                  size: AppIcon.chevron,
                  color: colors.accent,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
