import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../ui/app_field.dart';
import '../ui/show_sheet.dart';

/// 链接输入结果。
class LinkInput {
  const LinkInput({required this.label, required this.url});

  final String label;
  final String url;
}

/// 插入链接弹层：链接文字 + 链接地址。
///
/// 旧版 Aa 面板的「链接」只是把 `[文字](url)` 字面量塞进文档，新内核
/// 不会二次解析，页面上就是一串源码。这里用真正的输入弹层，确认后
/// 由 KernelCommands 插入带 LinkAttribution 的文本。
Future<LinkInput?> showLinkEditorSheet({
  required BuildContext context,
  required String initialLabel,
}) {
  return showXiaojiSheet<LinkInput>(
    context: context,
    builder: (BuildContext sheetContext) {
      return _LinkEditorSheet(initialLabel: initialLabel);
    },
  );
}

class _LinkEditorSheet extends StatefulWidget {
  const _LinkEditorSheet({required this.initialLabel});

  final String initialLabel;

  @override
  State<_LinkEditorSheet> createState() => _LinkEditorSheetState();
}

class _LinkEditorSheetState extends State<_LinkEditorSheet> {
  late final TextEditingController _labelController =
      TextEditingController(text: widget.initialLabel);
  late final TextEditingController _urlController =
      TextEditingController(text: 'https://');

  @override
  void dispose() {
    _labelController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  void _save() {
    final label = _labelController.text.trim();
    final url = _urlController.text.trim();
    if (label.isEmpty || url.isEmpty) {
      return;
    }
    Navigator.of(context).pop(LinkInput(label: label, url: url));
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '插入链接',
                style: AppText.sheetTitle.copyWith(color: colors.text),
              ),
              const SizedBox(height: 12),
              _LinkField(
                controller: _labelController,
                hint: '链接文字',
                autofocus: true,
              ),
              const SizedBox(height: 8),
              _LinkField(
                controller: _urlController,
                hint: 'https://',
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 20),
              Row(
                children: <Widget>[
                  Expanded(
                    child: AppSheetButton(
                      label: '取消',
                      background: colors.surface2,
                      foreground: colors.secondary,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: AppSheetButton(
                      label: '插入',
                      background: colors.accent,
                      foreground: colors.page,
                      onTap: _save,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LinkField extends StatelessWidget {
  const _LinkField({
    required this.controller,
    required this.hint,
    this.autofocus = false,
    this.keyboardType = TextInputType.text,
  });

  final TextEditingController controller;
  final String hint;
  final bool autofocus;
  final TextInputType keyboardType;

  @override
  Widget build(BuildContext context) {
    return AppTextField(
      controller: controller,
      hintText: hint,
      autofocus: autofocus,
      keyboardType: keyboardType,
    );
  }
}
