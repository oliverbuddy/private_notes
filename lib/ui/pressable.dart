import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 鸿蒙式轻按压反馈。
///
/// 全站只保留这一种按压效果：按下时轻微缩小 2%、降到 55% 不透明度，
/// 松开 120ms 回弹。避免各页面各写一套 `InkWell + highlightColor`。
///
/// 卡片和列表行用 [pressedColor] 走「整块蒙层」：文字不跟着变淡，
/// 看起来才像被手指按住（见首页两种密度）。
///
/// 用 [Listener] 而不是 `GestureDetector.onTapDown` 记录按压态：
/// 只有 `onLongPress`、没有 `onTap` 的行（例如长按菜单）也能有反馈，
/// 同时不会抢走 tap / longPress 的手势仲裁。
class AppPressable extends StatefulWidget {
  const AppPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.behavior = HitTestBehavior.opaque,
    this.pressedOpacity = 0.55,
    this.pressedScale = 0.98,
    this.pressedColor,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final HitTestBehavior behavior;

  /// 按下时的不透明度（iOS 约 50%–65%）。
  final double pressedOpacity;

  /// 按下时的缩放。卡片/行用 0.985，大面积元素可以关掉（传 1）。
  final double pressedScale;

  /// 按下时铺在内容上方的蒙层颜色（需带透明度）。
  ///
  /// 卡片/列表行传 [AppPress.overlay]：文字保持清晰，整块轻微压暗/提亮，
  /// 与语雀、Keep 的按压手感一致。为 null 时与旧版行为完全相同。
  final Color? pressedColor;

  final bool enabled;

  @override
  State<AppPressable> createState() => _AppPressableState();
}

class _AppPressableState extends State<AppPressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (!mounted || _pressed == value) {
      return;
    }
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final bool active = _pressed && widget.enabled;
    final Color? overlay = widget.pressedColor;
    final Widget body = overlay == null
        ? widget.child
        // 蒙层必须画在内容上方：卡片变灰但正文/缩略图不被淡出，
        // 松开时一起回到原色，观感就是「按下去、弹起来」。
        : Stack(
            children: <Widget>[
              widget.child,
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: active ? 1 : 0,
                    duration: AppMotion.fast,
                    curve: AppMotion.decelerate,
                    child: ColoredBox(color: overlay),
                  ),
                ),
              ),
            ],
          );
    return Listener(
      onPointerDown: widget.enabled ? (_) => _setPressed(true) : null,
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: GestureDetector(
        behavior: widget.behavior,
        onTap: widget.enabled ? widget.onTap : null,
        onLongPress: widget.enabled ? widget.onLongPress : null,
        child: AnimatedOpacity(
          opacity: active ? widget.pressedOpacity : 1,
          duration: AppMotion.fast,
          curve: AppMotion.decelerate,
          child: AnimatedScale(
            scale: active ? widget.pressedScale : 1,
            duration: AppMotion.fast,
            curve: AppMotion.decelerate,
            child: body,
          ),
        ),
      ),
    );
  }
}
