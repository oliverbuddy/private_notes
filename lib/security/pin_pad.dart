import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../theme/app_theme.dart';

/// PIN 点阵 + 应用内数字键盘。
///
/// 为什么不用系统 `TextField`：安卓输入法在 composing 状态下会和程序的
/// 文本状态竞争，手机实测出现过「退格后重新输入一位，输入框直接补满 6 位」
/// —— 退格不生效、一次输入补多位。PIN 是安全输入，不能依赖输入法的
/// composing 行为；用自绘键盘后每次点击只会产生一次确定的变化。
///
/// 视觉沿用 App 现有语言：次级底色圆角按键、次级文字、主色点阵。
class PinEntry extends StatelessWidget {
  const PinEntry({
    super.key,
    required this.value,
    required this.onChanged,
    this.maxLength = 6,
    this.error,
  });

  /// 已输入的数字（空串表示未输入）。
  final String value;
  final ValueChanged<String> onChanged;

  /// 最长 6 位。
  final int maxLength;

  /// 错误提示（不为空时显示在点阵下方）。
  final String? error;

  void _append(String digit) {
    if (value.length >= maxLength) {
      return;
    }
    HapticFeedback.selectionClick();
    onChanged('$value$digit');
  }

  void _backspace() {
    if (value.isEmpty) {
      return;
    }
    HapticFeedback.selectionClick();
    onChanged(value.substring(0, value.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _buildDots(colors),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: AppFontSize.meta, color: colors.danger),
            ),
          ),
        const SizedBox(height: 20),
        _buildKeyboard(colors),
      ],
    );
  }

  Widget _buildDots(AppColors colors) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        for (var i = 0; i < maxLength; i++)
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < value.length ? colors.accent : Colors.transparent,
              border: Border.all(
                color: i < value.length ? colors.accent : colors.dividerStrong,
                width: 1,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildKeyboard(AppColors colors) {
    return SizedBox(
      width: 280,
      child: Column(
        children: <Widget>[
          _buildRow(colors, const <String>['1', '2', '3']),
          _buildRow(colors, const <String>['4', '5', '6']),
          _buildRow(colors, const <String>['7', '8', '9']),
          Row(
            children: <Widget>[
              const Expanded(child: SizedBox(height: 60)),
              Expanded(child: _buildKey(colors, '0', _append)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: Material(
                    color: colors.surface2,
                    borderRadius: BorderRadius.circular(12),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: _backspace,
                      child: SizedBox(
                        height: 50,
                        child: Icon(
                          Icons.backspace_outlined,
                          size: 20,
                          color: colors.secondary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRow(AppColors colors, List<String> digits) {
    return Row(
      children: <Widget>[
        for (final String digit in digits)
          Expanded(child: _buildKey(colors, digit, _append)),
      ],
    );
  }

  Widget _buildKey(
    AppColors colors,
    String label,
    void Function(String) onTap,
  ) {
    return Padding(
      padding: const EdgeInsets.all(5),
      child: Material(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onTap(label),
          child: SizedBox(
            height: 50,
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: AppFontSize.title,
                  height: 1,
                  fontWeight: AppWeight.medium,
                  color: colors.text,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
