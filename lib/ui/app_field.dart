import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// 统一的鸿蒙输入框外观。
///
/// 所有「弹层里输入文字」的地方（标签添加、标签重命名、链接编辑等）都必须
/// 走这里，避免再出现「有的有底色、有的没有」：
/// - 填充 surface2，20 圆角，0.5 描边，聚焦时主色 1dp；
/// - 正文 16 / 提示 14 三级文字，内边距 14×12。
///
/// 首页搜索框是另一套语义（白面 + 18 圆角），不在这里。
InputDecoration appFieldDecoration(
  BuildContext context, {
  String? hintText,
  String? counterText,
  Widget? suffixIcon,
}) {
  final AppColors colors = AppColors.of(context);
  final OutlineInputBorder idle = OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppRadius.field),
    borderSide: BorderSide(color: colors.chipBorder, width: 0.5),
  );
  final OutlineInputBorder focused = OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppRadius.field),
    borderSide: BorderSide(color: colors.accent, width: 1),
  );
  return InputDecoration(
    isDense: true,
    filled: true,
    fillColor: colors.surface2,
    hintText: hintText,
    hintStyle: TextStyle(
      fontSize: AppFontSize.labelLg,
      color: colors.tertiary,
    ),
    counterText: counterText,
    suffixIcon: suffixIcon,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    border: idle,
    enabledBorder: idle,
    focusedBorder: focused,
    disabledBorder: idle,
  );
}

/// 全站统一的文本输入框。
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.controller,
    this.hintText,
    this.autofocus = false,
    this.keyboardType,
    this.textInputAction,
    this.maxLength,
    this.onSubmitted,
    this.onChanged,
    this.inputFormatters,
  });

  final TextEditingController controller;
  final String? hintText;
  final bool autofocus;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final int? maxLength;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return TextField(
      controller: controller,
      autofocus: autofocus,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      maxLength: maxLength,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      inputFormatters: inputFormatters,
      cursorColor: colors.accent,
      style: TextStyle(
        fontSize: AppFontSize.body,
        height: 1.3,
        color: colors.text,
      ),
      decoration: appFieldDecoration(
        context,
        hintText: hintText,
        counterText: maxLength == null ? null : '',
      ),
    );
  }
}
