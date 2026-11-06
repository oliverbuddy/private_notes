import 'package:flutter/material.dart';

import '../models/note.dart';
import '../theme/app_theme.dart';
import '../ui/show_sheet.dart';
import '../ui/tag_palette.dart';

/// 详情页「编辑标签」弹层：输入框只负责**新增**，已选标签在候选区里
/// 以选中态呈现。
///
/// 之前已选标签会回填进输入框（`旅行, 想法`），用户要删一个标签得手动
/// 删逗号和文字，既容易改坏又看不到候选（用户反馈）。改成滴答清单的
/// 做法：候选区点一下选中/取消，输入框永远为空，只用来加新标签。
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
  /// 已选标签。LinkedHashSet 语义：顺序稳定，保存后不会每次重排。
  late final Set<String> _selected =
      Set<String>.from(Note.parseTags(widget.initialText));

  /// 新增标签输入框：始终为空，提交后立刻清空（见 [_commitInput]）。
  late final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// 候选区 = 仓库已有标签 + 已选但不在候选里的标签（新加的、旧的）。
  List<String> get _candidates {
    final List<String> all = widget.candidates.toList();
    for (final String tag in _selected) {
      if (!all.contains(tag)) {
        all.add(tag);
      }
    }
    return all;
  }

  void _toggle(String tag) {
    setState(() {
      if (!_selected.remove(tag)) {
        _selected.add(tag);
      }
    });
  }

  /// 把输入框内容并入已选：与读盘、标签管理共用同一套清洗规则，
  /// 支持逗号一次输入多个，自动去掉前导 `#`。
  void _commitInput() {
    final String raw = _input.text.trim();
    if (raw.isEmpty) {
      return;
    }
    for (final String tag in Note.parseTags(raw)) {
      _selected.add(tag);
    }
    _input.clear();
  }

  void _addFromInput() {
    setState(_commitInput);
  }

  void _submit() {
    // 输入框里还没回车的标签不能丢：完成时一并收下。
    _commitInput();
    Navigator.of(context).pop(_selected.join(', '));
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final List<String> candidates = _candidates;
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
                  fontSize: AppFontSize.body,
                  fontWeight: AppWeight.medium,
                  color: colors.text,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _input,
                      autofocus: true,
                      maxLength: 20,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _addFromInput(),
                      style: TextStyle(fontSize: AppFontSize.hint, color: colors.text),
                      decoration: InputDecoration(
                        hintText: '输入新标签，回车添加',
                        hintStyle:
                            TextStyle(fontSize: AppFontSize.labelLg, color: colors.tertiary),
                        border: InputBorder.none,
                        isDense: true,
                        counterText: '',
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 回车与「添加」等价；输入为空时置灰，避免误点。
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _input,
                    builder: (BuildContext context, TextEditingValue value, _) {
                      final bool enabled = value.text.trim().isNotEmpty;
                      return TextButton(
                        onPressed: enabled ? _addFromInput : null,
                        child: Text(
                          '添加',
                          style: TextStyle(
                            fontSize: AppFontSize.labelLg,
                            color: enabled ? colors.accent : colors.tertiary,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
              if (candidates.isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  _selected.isEmpty ? '已有标签' : '标签（点一下选中/取消）',
                  style: TextStyle(fontSize: AppFontSize.meta, color: colors.tertiary),
                ),
                const SizedBox(height: 8),
                // 候选可能很多：限制高度并允许滚动，避免把弹层撑出屏幕。
                // 之前只取前 12 个，后面的标签根本选不到。
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        for (final String tag in candidates)
                          _TagCandidateChip(
                            label: tag,
                            selected: _selected.contains(tag),
                            onTap: () => _toggle(tag),
                          ),
                      ],
                    ),
                  ),
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
                      label: '完成',
                      background: colors.accent,
                      foreground: colors.page,
                      onTap: _submit,
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

/// 候选标签 chip：点一下选中/取消；颜色就是该标签在列表/详情里的颜色。
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
    final TagTone tone = TagPalette.toneFor(label, colors);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.chip),
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: selected ? tone.background : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(
            color: selected ? tone.border : colors.chipBorder,
            width: 0.5,
          ),
        ),
        child: Center(
          widthFactor: 1,
          child: Text(
            '#$label',
            style: TextStyle(
              fontSize: AppFontSize.label,
              height: 1,
              color: tone.foreground,
              fontWeight: selected ? AppWeight.medium : AppWeight.regular,
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
              fontSize: AppFontSize.body,
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
