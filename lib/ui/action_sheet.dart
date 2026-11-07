import 'package:flutter/material.dart';

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

/// 统一的底部动作菜单（主页长按、详情「⋯」等）。
///
/// HarmonyOS 菜单规格：标题 20 Medium 左对齐、行高 56、24 图标、
/// 0.5 分隔线（左缩进 16）、底部独立的 40 高「取消」按钮。
/// 与确认弹层、选项弹层共用同一套弹层动画与安全区。
Future<T?> showXiaojiActionSheet<T>({
  required BuildContext context,
  required String title,
  required List<SheetAction<T>> actions,
}) {
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
                Icon(Icons.check, size: AppIcon.chevron, color: colors.accent),
            ],
          ),
        ),
      ),
    );
  }
}
