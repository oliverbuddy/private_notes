import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'pressable.dart';

/// 桌面右键 / 长按菜单里的一项。
class DesktopMenuEntry<T> {
  const DesktopMenuEntry({
    required this.label,
    required this.value,
    this.enabled = true,
    this.destructive = false,
    this.dividerBefore = false,
  });

  final String label;
  final T value;
  final bool enabled;
  final bool destructive;

  /// 在这一项之前画一条分隔线（分组用）。
  final bool dividerBefore;
}

/// 桌面右键菜单：直接插入 Overlay，不 push 路由。
///
/// 为什么不用 `showMenu`：它会 push 一条路由并接管焦点，
/// SuperEditor 在焦点变化时会收起选区 —— 用户看到的正是「右键后蓝色选中底
/// 消失」。Overlay 方案不改变焦点，因此选区、光标、滚动位置都保持原样；
/// 视觉上也与其它动作菜单共用同一份规格（8 圆角、0.5 描边、40 行高）。
Future<T?> showDesktopMenu<T>({
  required BuildContext context,
  required Offset globalPosition,
  required List<DesktopMenuEntry<T>> entries,
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
      const double menuWidth = 220;
      const double rowHeight = 40;
      final double menuHeight = entries.length * rowHeight + 8;
      // 贴住指针弹出，越界时回收到屏幕内。
      final double left =
          globalPosition.dx + menuWidth > screen.width - 8
              ? (screen.width - menuWidth - 8).clamp(8.0, screen.width)
              : globalPosition.dx.clamp(0.0, screen.width - menuWidth);
      final double top =
          globalPosition.dy + menuHeight > screen.height - 8
              ? (screen.height - menuHeight - 8).clamp(8.0, screen.height)
              : globalPosition.dy;

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
          Positioned(
            left: left,
            top: top,
            width: menuWidth,
            child: Material(
              color: Colors.transparent,
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
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
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
                        height: rowHeight,
                        onTap: () => close(entry.value),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );

  overlay.insert(overlayEntry);
  HardwareKeyboard.instance.addHandler(handleKey);
  return completer.future;
}

class _DesktopMenuRow<T> extends StatelessWidget {
  const _DesktopMenuRow({
    required this.entry,
    required this.height,
    required this.onTap,
  });

  final DesktopMenuEntry<T> entry;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Color foreground = entry.enabled
        ? (entry.destructive ? colors.danger : colors.text)
        : colors.tertiary;
    return AppPressable(
      enabled: entry.enabled,
      onTap: entry.enabled ? onTap : null,
      pressedScale: 1,
      pressedColor: AppPress.overlay(context),
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              entry.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppFontSize.labelLg,
                color: foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
