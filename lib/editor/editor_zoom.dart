import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 详情页正文缩放（会话内生效）。
///
/// 只缩放正文排版，不影响首页/设置页的信息密度 —— 桌面竞品的「缩放」
/// 通常会把整个界面放大，侧边栏反而变得拥挤；这里只放大正在阅读的正文。
final ValueNotifier<double> editorZoom = ValueNotifier<double>(1.0);

const double kEditorZoomMin = 0.85;
const double kEditorZoomMax = 1.4;
const double kEditorZoomStep = 0.05;

/// 缩放一档。[delta] 为负表示缩小。
///
/// 边界用 clamp 收口：缩到 0.85 以下正文会明显小于侧边栏，放到 1.4 以上
/// 表格与代码块就会开始横向溢出，都不如直接停在边界。
void adjustEditorZoom(double delta) {
  final double next = (editorZoom.value + delta).clamp(
    kEditorZoomMin,
    kEditorZoomMax,
  );
  if ((next - editorZoom.value).abs() > 0.001) {
    editorZoom.value = next;
  }
}

/// 恢复默认字号（⌘0）。
void resetEditorZoom() {
  editorZoom.value = 1.0;
}

/// 把 ⌘= / ⌘- / ⌘0（Windows 用 Ctrl）绑到正文缩放上。
///
/// 抽成独立组件（而不是写进 main.dart 的私有快捷方式里）是为了让测试
/// 能直接包住编辑页验证「快捷键 → 字号」的完整链路。
class EditorZoomShortcuts extends StatelessWidget {
  const EditorZoomShortcuts({super.key, required this.child});

  final Widget child;

  /// 缩放快捷键表。
  ///
  /// 同时覆盖 Meta（macOS）与 Control（Windows），用循环生成而不是手写
  /// 十几条重复绑定。
  static final Map<ShortcutActivator, Intent> _bindings = _buildBindings();

  /// `=`（含 Shift 的 `+`）、小键盘 `+`、`-`、`0` 在两种修饰键下的组合。
  static Map<ShortcutActivator, Intent> _buildBindings() {
    final Map<ShortcutActivator, Intent> map = <ShortcutActivator, Intent>{};
    for (final bool meta in const <bool>[true, false]) {
      // `⌘+` 在 macOS 上其实是 Shift+=，所以两档都要绑。
      for (final bool shift in const <bool>[true, false]) {
        map[_activator(LogicalKeyboardKey.equal, meta, shift)] =
            const _ZoomInIntent();
        map[_activator(LogicalKeyboardKey.numpadAdd, meta, shift)] =
            const _ZoomInIntent();
      }
      map[_activator(LogicalKeyboardKey.minus, meta)] = const _ZoomOutIntent();
      map[_activator(LogicalKeyboardKey.numpadSubtract, meta)] =
          const _ZoomOutIntent();
      map[_activator(LogicalKeyboardKey.digit0, meta)] =
          const _ZoomResetIntent();
      map[_activator(LogicalKeyboardKey.numpad0, meta)] =
          const _ZoomResetIntent();
    }
    return map;
  }

  static SingleActivator _activator(
    LogicalKeyboardKey key,
    bool meta, [
    bool shift = false,
  ]) {
    return SingleActivator(
      key,
      meta: meta,
      control: !meta,
      shift: shift,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: _bindings,
      child: Actions(
        actions: <Type, Action<Intent>>{
          _ZoomInIntent: CallbackAction<_ZoomInIntent>(
            onInvoke: (_) {
              adjustEditorZoom(kEditorZoomStep);
              return null;
            },
          ),
          _ZoomOutIntent: CallbackAction<_ZoomOutIntent>(
            onInvoke: (_) {
              adjustEditorZoom(-kEditorZoomStep);
              return null;
            },
          ),
          _ZoomResetIntent: CallbackAction<_ZoomResetIntent>(
            onInvoke: (_) {
              resetEditorZoom();
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }
}

class _ZoomInIntent extends Intent {
  const _ZoomInIntent();
}

class _ZoomOutIntent extends Intent {
  const _ZoomOutIntent();
}

class _ZoomResetIntent extends Intent {
  const _ZoomResetIntent();
}
