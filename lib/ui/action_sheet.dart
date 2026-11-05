import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
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

/// 统一的底部动作菜单（图片长按菜单等）。
///
/// 与确认弹层共用同一套弹层动画、grabber 和安全区；列表项 52dp 高，
/// 末项「取消」用浅底圆角按钮，符合国内 App 的通行样式。
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
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
                  child: Text(
                    title,
                    style: AppText.sheetTitle.copyWith(color: colors.text),
                  ),
                ),
              for (var i = 0; i < actions.length; i++) ...<Widget>[
                if (i > 0)
                  Container(height: 0.5, color: colors.divider),
                _ActionRow<T>(action: actions[i]),
              ],
              const SizedBox(height: 12),
              Material(
                color: colors.surface2,
                borderRadius: BorderRadius.circular(10),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => Navigator.of(sheetContext).pop(),
                  child: SizedBox(
                    height: 52,
                    child: Center(
                      child: Text(
                        '取消',
                        style: TextStyle(
                          fontSize: 16,
                          height: 1,
                          fontWeight: AppWeight.medium,
                          color: colors.secondary,
                        ),
                      ),
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
    return InkWell(
      onTap: () => Navigator.of(context).pop(action.value),
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: <Widget>[
              if (action.icon != null) ...<Widget>[
                Icon(action.icon, size: 20, color: foreground),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  action.label,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1,
                    fontWeight: action.selected
                        ? AppWeight.medium
                        : AppWeight.regular,
                    color: foreground,
                  ),
                ),
              ),
              if (action.selected)
                Icon(Icons.check, size: 18, color: colors.accent),
            ],
          ),
        ),
      ),
    );
  }
}
