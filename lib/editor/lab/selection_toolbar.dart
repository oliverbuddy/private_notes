import 'package:flutter/material.dart';
import 'package:follow_the_leader/follow_the_leader.dart';
import 'package:super_editor/super_editor.dart';

/// 小记的 Android 选择工具条（中文）。
///
/// 为什么不用 super_editor 内建的 `DefaultAndroidEditorToolbar`：它内部的
/// `AndroidTextEditingFloatingToolbar` 把按钮文案写死英文（Copy/Paste/
/// Select All，源码实测），且 SuperEditor 的 `androidToolbarBuilder` 公开
/// 参数在 0.3.0-dev.52 是死参数。而 `SuperEditorAndroidControlsController
/// .toolbarBuilder` 是活的（OverlayManager 优先取它），所以从这里注入。
///
/// 观感：深色胶囊浮在选区上方（微信/语雀同款），文案走系统中文本地化。
/// 定位与屏幕边界避让由内核的 Follower 体系负责（toolbarBuilder 外层已包）。
class XiaojiSelectionToolbar extends StatefulWidget {
  const XiaojiSelectionToolbar({
    super.key,
    required this.floatingToolbarKey,
    required this.focalPoint,
    required this.editorOps,
    required this.controls,
  });

  final Key floatingToolbarKey;
  final LeaderLink focalPoint;
  final CommonEditorOperations editorOps;
  final SuperEditorAndroidControlsController controls;

  @override
  State<XiaojiSelectionToolbar> createState() =>
      _XiaojiSelectionToolbarState();
}

class _XiaojiSelectionToolbarState extends State<XiaojiSelectionToolbar> {
  bool _isAbove = true;

  @override
  void initState() {
    super.initState();
    widget.focalPoint.addListener(_onFocalPointChange);
  }

  @override
  void didUpdateWidget(XiaojiSelectionToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focalPoint != widget.focalPoint) {
      oldWidget.focalPoint.removeListener(_onFocalPointChange);
      widget.focalPoint.addListener(_onFocalPointChange);
    }
  }

  @override
  void dispose() {
    widget.focalPoint.removeListener(_onFocalPointChange);
    super.dispose();
  }

  /// 工具条出现在锚点上方还是下方（照抄官方实现：比较渲染框与锚点偏移）。
  void _onFocalPointChange() {
    final leader = widget.focalPoint.leader;
    if (leader == null) {
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) {
      return;
    }
    final isAbove = box.localToGlobal(Offset.zero).dy < leader.offset.dy;
    if (isAbove != _isAbove) {
      setState(() => _isAbove = isAbove);
    }
  }

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final brightness = Theme.of(context).brightness;
    // 胶囊用反色：浅色页面黑胶囊白字，深色页面白胶囊黑字，
    // 无论笔记底色如何都够对比（微信同款思路）。
    final background =
        brightness == Brightness.light ? Colors.black87 : Colors.white;
    final foreground =
        brightness == Brightness.light ? Colors.white : Colors.black87;

    void run(VoidCallback action) {
      action();
      widget.controls.hideToolbar();
    }

    return KeyedSubtree(
      key: widget.floatingToolbarKey,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _button(localizations.copyButtonLabel, foreground,
                () => run(widget.editorOps.copy)),
            _button(localizations.cutButtonLabel, foreground,
                () => run(widget.editorOps.cut)),
            _button(localizations.pasteButtonLabel, foreground,
                () => run(widget.editorOps.paste)),
            _button(localizations.selectAllButtonLabel, foreground,
                () => run(widget.editorOps.selectAll)),
          ],
        ),
      ),
    );
  }

  Widget _button(String label, Color foreground, VoidCallback onPressed) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(
          label,
          style: TextStyle(fontSize: 14, color: foreground),
        ),
      ),
    );
  }
}
