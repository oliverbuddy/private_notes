import 'package:flutter/material.dart';

import '../platform/platform_features.dart';
import '../theme/app_theme.dart';
import 'pressable.dart';
import 'show_sheet.dart';

/// 底部动作菜单里的一项。
class SheetAction<T> {
  const SheetAction({
    required this.value,
    required this.label,
    this.icon,
    this.destructive = false,
    this.selected = false,
  });

  /// 选中后通过 [showXiaojiActionSheet] 返回给调用方。
  final T value;

  final String label;
  final IconData? icon;

  /// 危险操作（红色文字），用于删除。
  final bool destructive;

  /// 当前生效项：文字用主色并显示对勾（用于「小图/大图」这类单选）。
  final bool selected;
}

/// 触发按钮的全局矩形，用来把桌面菜单锚定在按钮下方。
///
/// 取不到（按钮还没布局）时返回 null，调用方退回居中/底部弹层。
Rect? anchorRectOf(GlobalKey key) {
  final RenderObject? renderObject = key.currentContext?.findRenderObject();
  if (renderObject is! RenderBox ||
      !renderObject.attached ||
      !renderObject.hasSize) {
    return null;
  }
  return renderObject.localToGlobal(Offset.zero) & renderObject.size;
}

/// 统一的动作菜单（主页长按/右键、详情「⋯」等）。
///
/// 桌面端：锚定在触发按钮下方的小弹窗（与 macOS / Windows 原生菜单
/// 一致：贴住触发点、点空白即关、可用方向键移动）。
/// 移动端：沿用底部动作菜单（HarmonyOS 规格，见下方实现）。
Future<T?> showXiaojiActionSheet<T>({
  required BuildContext context,
  required String title,
  required List<SheetAction<T>> actions,
  Rect? anchor,
}) {
  if (PlatformFeatures.isDesktop && anchor != null) {
    return _showDesktopActionMenu<T>(
      context: context,
      title: title,
      actions: actions,
      anchor: anchor,
    );
  }
  return showXiaojiSheet<T>(
    context: context,
    builder: (BuildContext sheetContext) {
      final AppColors colors = AppColors.of(sheetContext);
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.sheetTitle.copyWith(color: colors.text),
                  ),
                ),
              for (var i = 0; i < actions.length; i++) ...<Widget>[
                if (i > 0)
                  Divider(
                    height: 0.5,
                    thickness: 0.5,
                    indent: AppSpace.lg,
                    color: colors.divider,
                  ),
                _ActionRow<T>(action: actions[i]),
              ],
              const SizedBox(height: 8),
              AppPressable(
                onTap: () => Navigator.of(sheetContext).pop(),
                pressedScale: 1,
                child: Container(
                  height: AppSize.button,
                  alignment: Alignment.center,
                  decoration: ShapeDecoration(
                    color: colors.surface2,
                    shape: AppShape.continuous(AppRadius.button),
                  ),
                  child: Text(
                    '取消',
                    style: TextStyle(
                      fontSize: AppFontSize.body,
                      height: 1,
                      fontWeight: AppWeight.medium,
                      color: colors.accent,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// 桌面端的锚定动作菜单：紧贴触发按钮下方，标准 `showMenu` 交互。
Future<T?> _showDesktopActionMenu<T>({
  required BuildContext context,
  required String title,
  required List<SheetAction<T>> actions,
  required Rect anchor,
}) {
  final RenderObject? overlayObject =
      Overlay.of(context).context.findRenderObject();
  if (overlayObject is! RenderBox) {
    return Future<T?>.value();
  }
  final AppColors colors = AppColors.of(context);
  // 菜单从按钮下沿展开，不会盖住按钮本身。
  final Rect position = Rect.fromLTWH(
    anchor.left,
    anchor.bottom + 2,
    anchor.width,
    0,
  );
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(position, Offset.zero & overlayObject.size),
    color: colors.page,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadius.block),
      side: BorderSide(color: colors.chipBorder, width: 0.5),
    ),
    items: <PopupMenuEntry<T>>[
      if (title.isNotEmpty)
        PopupMenuItem<T>(
          enabled: false,
          height: 34,
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: AppFontSize.caption, color: colors.tertiary),
          ),
        ),
      for (final SheetAction<T> action in actions)
        PopupMenuItem<T>(
          value: action.value,
          height: 40,
          child: Row(
            children: <Widget>[
              if (action.icon != null) ...<Widget>[
                Icon(
                  action.icon,
                  size: AppIcon.compact,
                  color: action.destructive
                      ? colors.danger
                      : (action.selected ? colors.accent : colors.text),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppFontSize.labelLg,
                    color: action.destructive
                        ? colors.danger
                        : (action.selected ? colors.accent : colors.text),
                  ),
                ),
              ),
              if (action.selected)
                Icon(
                  Icons.check_rounded,
                  size: AppIcon.chevron,
                  color: colors.accent,
                ),
            ],
          ),
        ),
    ],
  );
}

class _ActionRow<T> extends StatelessWidget {
  const _ActionRow({required this.action});

  final SheetAction<T> action;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final Color foreground = action.destructive
        ? colors.danger
        : (action.selected ? colors.accent : colors.text);
    return AppPressable(
      onTap: () => Navigator.of(context).pop(action.value),
      pressedScale: 1,
      child: SizedBox(
        height: AppSize.actionRow,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
          child: Row(
            children: <Widget>[
              if (action.icon != null) ...<Widget>[
                Icon(action.icon, size: AppIcon.action, color: foreground),
                const SizedBox(width: AppSpace.md),
              ],
              Expanded(
                child: Text(
                  action.label,
                  style: TextStyle(
                    fontSize: AppFontSize.body,
                    height: 1,
                    fontWeight: action.selected
                        ? AppWeight.semibold
                        : AppWeight.regular,
                    color: foreground,
                  ),
                ),
              ),
              if (action.selected)
                Icon(Icons.check_rounded, size: AppIcon.chevron, color: colors.accent),
            ],
          ),
        ),
      ),
    );
  }
}
