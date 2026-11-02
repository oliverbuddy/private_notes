import 'package:flutter/material.dart';

import '../models/note.dart';
import '../theme/app_theme.dart';
import '../ui/show_sheet.dart';

/// 详情页「编辑标签」弹层：输入框 + 已有标签候选 chips。
///
/// 旧版编辑器有候选标签，迁移到新内核时被简化成纯输入框了
/// （用户反馈「候选标签呢」）。这里做成独立 widget，控制器跟着
/// 弹层树销毁，避免 old editor 踩过的「pop 后立刻 dispose 控制器，
/// 退场动画期间 TextField 崩溃」。
Future<String?> showTagEditorSheet({
  required BuildContext context,
  required String initialText,
  required List<String> candidates,
}) {
  return showXiaojiSheet<String>(
    context: context,
    builder: (BuildContext sheetContext) {
      return _TagEditorSheet(
        initialText: initialText,
        candidates: candidates,
      );
    },
  );
}

class _TagEditorSheet extends StatefulWidget {
  const _TagEditorSheet({
    required this.initialText,
    required this.candidates,
  });

  final String initialText;
  final List<String> candidates;

  @override
  State<_TagEditorSheet> createState() => _TagEditorSheetState();
}

class _TagEditorSheetState extends State<_TagEditorSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<String> get _selected => Note.parseTags(_controller.text);

  void _toggle(String tag) {
    final next = Note.parseTags(_controller.text);
    if (next.contains(tag)) {
      next.remove(tag);
    } else {
      next.add(tag);
    }
    final text = next.join(', ');
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final selected = _selected;
    return Padding(
      // 键盘是系统层，压得住 bottom sheet；让出 viewInsets 后输入框
      // 才会浮在键盘上沿，而不是被挡在键盘后面。
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '标签',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: AppWeight.medium,
                  color: colors.text,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                style: TextStyle(fontSize: 15, color: colors.text),
                decoration: InputDecoration(
                  hintText: '逗号分隔，例如：旅行, 想法',
                  hintStyle: TextStyle(fontSize: 13.5, color: colors.tertiary),
                  border: InputBorder.none,
                ),
              ),
              if (widget.candidates.isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  '已有标签',
                  style: TextStyle(fontSize: 12.5, color: colors.tertiary),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final tag in widget.candidates)
                      _TagCandidateChip(
                        label: tag,
                        selected: selected.contains(tag),
                        onTap: () => _toggle(tag),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _TagSheetButton(
                      label: '取消',
                      background: colors.surface2,
                      foreground: colors.secondary,
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _TagSheetButton(
                      // 语义是「把标签加到这条小记」，不是保存正文（正文自动保存）。
                      label: '添加',
                      background: colors.accent,
                      foreground: colors.page,
                      onTap: () => Navigator.of(context).pop(_controller.text),
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

/// 候选标签 chip：点一下在输入文本里增删该标签。
class _TagCandidateChip extends StatelessWidget {
  const _TagCandidateChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.chip),
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: selected ? colors.accentBg : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(
            color: selected ? colors.chipBorderSelected : colors.chipBorder,
            width: 0.5,
          ),
        ),
        child: Center(
          widthFactor: 1,
          child: Text(
            '#$label',
            style: TextStyle(
              fontSize: 13,
              height: 1,
              color: selected ? colors.accent : colors.secondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 保存 / 取消按钮：52 高、圆角 10，和确认弹层同一规格。
class _TagSheetButton extends StatelessWidget {
  const _TagSheetButton({
    required this.label,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  final String label;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(AppRadius.card),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 52,
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 16,
              height: 1,
              fontWeight: AppWeight.medium,
              color: foreground,
            ),
          ),
        ),
      ),
    );
  }
}
