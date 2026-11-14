import 'package:flutter/material.dart';

import '../models/note.dart';
import '../theme/app_theme.dart';
import '../ui/app_field.dart';
import '../ui/show_sheet.dart';
import '../ui/tag_palette.dart';

/// 详情页「编辑标签」弹层：输入框只负责**新增**，已选标签单独一栏
/// 以彩色胶囊呈现（点一下取消），未选标签在「全部标签」里以中性胶囊
/// 呈现（点一下选中）。
///
/// 之前已选标签会回填进输入框（`旅行, 想法`），用户要删一个标签得手动
/// 删逗号和文字，既容易改坏又看不到候选（用户反馈）。后来改成候选区
/// 全部混排，标签一多就得滚动着找已选项 —— 这里按主流做法分区：
/// 已选在前、未选在后，互不打扰。
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
    final AppColors colors = AppColors.of(context);
    final List<String> selected = _selected.toList(growable: false);
    // 未选候选：已选的不再重复出现在下面，少滚动、也更清楚。
    final List<String> available = widget.candidates
        .where((String tag) => !_selected.contains(tag))
        .toList(growable: false);

    return Padding(
      // 键盘是系统层，压得住 bottom sheet；让出 viewInsets 后输入框
      // 才会浮在键盘上沿，而不是被挡在键盘后面。
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.page,
            AppSpace.xs,
            AppSpace.page,
            AppSpace.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '标签',
                      style:
                          AppText.sheetTitle.copyWith(color: colors.text),
                    ),
                  ),
                  // 标题右侧显示已选数量：点选后不用去数胶囊也能确认。
                  if (selected.isNotEmpty)
                    Text(
                      '已选 ${selected.length}',
                      style: TextStyle(
                        fontSize: AppFontSize.meta,
                        color: colors.tertiary,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpace.md),
              Row(
                children: <Widget>[
                  Expanded(
                    child: AppTextField(
                      controller: _input,
                      autofocus: true,
                      maxLength: 20,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _addFromInput(),
                      hintText: '输入新标签，回车添加',
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  // 回车与「添加」等价；输入为空时置灰，避免误点。
                  // 用 44 方形图标按钮和输入框等高，比默认 48 高的
                  // TextButton 更贴合这一行。
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _input,
                    builder: (BuildContext context, TextEditingValue value, _) {
                      final bool enabled = value.text.trim().isNotEmpty;
                      return IconButton(
                        onPressed: enabled ? _addFromInput : null,
                        tooltip: '添加标签',
                        icon: const Icon(Icons.add_rounded),
                        iconSize: AppIcon.dense,
                        style: IconButton.styleFrom(
                          backgroundColor: colors.accent,
                          foregroundColor: colors.page,
                          disabledBackgroundColor: colors.surface2,
                          disabledForegroundColor: colors.tertiary,
                          minimumSize: const Size.square(44),
                          padding: EdgeInsets.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.all(
                              Radius.circular(AppRadius.field),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
              if (selected.isNotEmpty || available.isNotEmpty) ...<Widget>[
                const SizedBox(height: AppSpace.lg),
                // 内容区限高滚动：小屏 + 键盘弹出时不会把弹层撑出屏幕，
                // 底部按钮始终可见（不再用候选区内部的嵌套滚动）。
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (selected.isNotEmpty)
                          Wrap(
                            spacing: AppSpace.sm,
                            runSpacing: AppSpace.sm,
                            children: <Widget>[
                              for (final String tag in selected)
                                _TagCandidateChip(
                                  label: tag,
                                  selected: true,
                                  onTap: () => _toggle(tag),
                                ),
                            ],
                          ),
                        if (available.isNotEmpty) ...<Widget>[
                          if (selected.isNotEmpty)
                            const SizedBox(height: AppSpace.lg),
                          Text(
                            '全部标签',
                            style: TextStyle(
                              fontSize: AppFontSize.meta,
                              color: colors.tertiary,
                            ),
                          ),
                          const SizedBox(height: AppSpace.sm),
                          Wrap(
                            spacing: AppSpace.sm,
                            runSpacing: AppSpace.sm,
                            children: <Widget>[
                              for (final String tag in available)
                                _TagCandidateChip(
                                  label: tag,
                                  selected: false,
                                  onTap: () => _toggle(tag),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: AppSpace.xl),
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
                  const SizedBox(width: AppSpace.md),
                  Expanded(
                    child: AppSheetButton(
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

/// 候选标签 chip：已选用彩色（带 ×，点一下取消），未选用中性色
/// （带一个该标签的颜色圆点，点一下选中）。
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
    final AppColors colors = AppColors.of(context);
    final TagTone tone = TagPalette.toneFor(label, colors);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.chip),
      child: Container(
        height: 28,
        padding: EdgeInsets.only(
          left: 9,
          right: selected ? 7 : 9,
        ),
        decoration: BoxDecoration(
          color: selected ? tone.background : colors.surface2,
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(
            color: selected ? tone.border : colors.chipBorder,
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 未选态留一个色点：标签颜色仍然一眼可辨，但整体是中性色。
            if (!selected) ...<Widget>[
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: tone.foreground,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
            ],
            Text(
              '#$label',
              style: TextStyle(
                fontSize: AppFontSize.label,
                height: 1,
                color: selected ? tone.foreground : colors.secondary,
                fontWeight:
                    selected ? AppWeight.medium : AppWeight.regular,
              ),
            ),
            if (selected) ...<Widget>[
              const SizedBox(width: 4),
              Icon(
                Icons.close_rounded,
                size: AppIcon.badge,
                color: tone.foreground.withValues(alpha: 0.8),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
