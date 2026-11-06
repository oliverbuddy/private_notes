import 'package:flutter/material.dart';

import '../data/note_repository.dart';
import '../models/note.dart';
import '../theme/app_theme.dart';
import '../ui/action_sheet.dart';
import '../ui/show_sheet.dart';
import '../ui/snack.dart';

/// 标签管理：重命名 / 合并 / 删除（从所有笔记里移除）。
///
/// 标签只存在于各篇笔记的 frontmatter 里，没有独立的标签表 —— 所以
/// 「管理」本质上是对全部笔记做一次批量改写，页面只负责展示与确认。
/// 点一行直接回首页按该标签筛选；管理动作收在行尾「…」里。
class TagsPage extends StatelessWidget {
  const TagsPage({super.key, required this.repository});

  final NoteRepository repository;

  Future<void> _showActions(
    BuildContext context,
    String tag,
    int count,
  ) async {
    final String? action = await showXiaojiActionSheet<String>(
      context: context,
      title: '#$tag',
      actions: <SheetAction<String>>[
        const SheetAction<String>(
          value: 'rename',
          label: '重命名',
          icon: Icons.drive_file_rename_outline,
        ),
        const SheetAction<String>(
          value: 'merge',
          label: '合并到其他标签',
          icon: Icons.merge_type,
        ),
        const SheetAction<String>(
          value: 'delete',
          label: '删除标签',
          icon: Icons.label_off_outlined,
          destructive: true,
        ),
      ],
    );
    if (!context.mounted || action == null) {
      return;
    }
    if (action == 'rename') {
      await _rename(context, tag);
    } else if (action == 'merge') {
      await _merge(context, tag, count);
    } else if (action == 'delete') {
      await _delete(context, tag, count);
    }
  }

  /// 点一行 = 回首页并按该标签筛选（看笔记是最高频的诉求）。
  void _openTag(BuildContext context, String tag) {
    repository.setActiveTag(tag);
    Navigator.of(context).popUntil((Route<dynamic> route) => route.isFirst);
  }

  Future<void> _rename(BuildContext context, String tag) async {
    final String? name = await _promptName(context, tag);
    if (name == null || !context.mounted) {
      return;
    }
    // 与编辑页、读盘共用同一套清洗规则：去 #、去空白；含逗号时这里直接提示，
    // 不再把「工作, 生活」写成一个坏标签。
    final String? target = Note.normalizeTag(name);
    if (target == null) {
      showSnack(context, message: '标签名不能包含逗号');
      return;
    }
    final int affected = await repository.renameTag(tag, target);
    if (context.mounted) {
      showSnack(
        context,
        message: affected == 0
            ? '标签名没有变化'
            : '已重命名为「$target」，共 $affected 条',
      );
    }
  }

  /// 合并到另一个标签：复用 [NoteRepository.renameTag] 的去重逻辑，
  /// 两条标签都存在的笔记不会出现重复标签。
  Future<void> _merge(BuildContext context, String tag, int count) async {
    final List<String> others = repository.tagCounts.keys
        .where((String item) => item != tag)
        .toList();
    if (others.isEmpty) {
      showSnack(context, message: '还没有其他标签可以合并');
      return;
    }
    final String? target = await _pickMergeTarget(context, tag, count);
    if (target == null || !context.mounted) {
      return;
    }
    final int affected = await repository.renameTag(tag, target);
    if (context.mounted) {
      showSnack(context, message: '已合并到「$target」，共 $affected 条');
    }
  }

  Future<String?> _pickMergeTarget(
    BuildContext context,
    String tag,
    int count,
  ) {
    final Map<String, int> counts = repository.tagCounts;
    final List<String> names = counts.keys
        .where((String item) => item != tag)
        .toList()
      ..sort();
    return showXiaojiSheet<String>(
      context: context,
      builder: (BuildContext sheetContext) {
        final AppColors colors = AppColors.of(sheetContext);
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '合并到',
                  style: AppText.sheetTitle.copyWith(color: colors.text),
                ),
                const SizedBox(height: 6),
                Text(
                  '「#$tag」下的 $count 条小记会改挂到目标标签，正文不变。',
                  style: TextStyle(
                    fontSize: AppFontSize.caption,
                    height: 1.6,
                    color: colors.tertiary,
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: names.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 0.5,
                      color: colors.divider,
                    ),
                    itemBuilder: (BuildContext context, int index) {
                      final String name = names[index];
                      return InkWell(
                        onTap: () =>
                            Navigator.of(sheetContext).pop(name),
                        child: SizedBox(
                          height: 52,
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  '#$name',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: AppFontSize.body,
                                    color: colors.text,
                                  ),
                                ),
                              ),
                              Text(
                                '${counts[name] ?? 0} 条',
                                style: TextStyle(
                                  fontSize: AppFontSize.value,
                                  color: colors.secondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _delete(BuildContext context, String tag, int count) async {
    final bool? confirmed = await showXiaojiConfirmSheet(
      context: context,
      title: '删除标签「$tag」？',
      message: '会从 $count 条小记里移除这个标签，正文不受影响。',
      confirmLabel: '删除标签',
      destructive: true,
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    final int affected = await repository.deleteTag(tag);
    if (context.mounted) {
      showSnack(context, message: '已从 $affected 条小记里移除');
    }
  }

  /// 重命名输入弹层。用应用内底部弹层而不是 AlertDialog，
  /// 与其它输入（设置 PIN、标签编辑）保持同一套视觉语言。
  Future<String?> _promptName(BuildContext context, String current) {
    final TextEditingController controller =
        TextEditingController(text: current);
    return showXiaojiSheet<String>(
      context: context,
      builder: (BuildContext sheetContext) {
        final colors = AppColors.of(sheetContext);
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(sheetContext).viewInsets.bottom,
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
                    '重命名标签',
                    style:
                        AppText.sheetTitle.copyWith(color: colors.text),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    maxLength: 20,
                    style: TextStyle(fontSize: AppFontSize.body, color: colors.text),
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: '标签名',
                      hintStyle: TextStyle(color: colors.tertiary),
                      filled: true,
                      fillColor: colors.surface2,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppRadius.card),
                        borderSide:
                            BorderSide(color: colors.chipBorder, width: 0.5),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppRadius.card),
                        borderSide:
                            BorderSide(color: colors.accent, width: 1),
                      ),
                    ),
                    onSubmitted: (String value) =>
                        Navigator.of(sheetContext).pop(value.trim()),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          child: Text(
                            '取消',
                            style: TextStyle(fontSize: AppFontSize.hint, color: colors.secondary),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextButton(
                          onPressed: () => Navigator.of(sheetContext)
                              .pop(controller.text.trim()),
                          style: TextButton.styleFrom(
                            backgroundColor: colors.accent,
                            foregroundColor: colors.page,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(AppRadius.card),
                            ),
                          ),
                          child: const Text('保存'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    final Color background = isDark ? colors.page : colors.pageAlt;
    final Color cardColor = isDark ? colors.pageAlt : colors.page;

    return Scaffold(
      backgroundColor: background,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: repository,
          builder: (BuildContext context, Widget? child) {
            final Map<String, int> counts = repository.tagCounts;
            // 与首页筛选条一致：使用次数降序，同次数按名称，保证顺序稳定。
            final List<String> names = counts.keys.toList()
              ..sort((String a, String b) {
                final int diff = (counts[b] ?? 0).compareTo(counts[a] ?? 0);
                return diff != 0 ? diff : a.compareTo(b);
              });
            return Column(
              children: <Widget>[
                _buildHeader(context, colors),
                Expanded(
                  child: names.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Text(
                                '还没有标签',
                                style: TextStyle(
                                  fontSize: AppFontSize.value,
                                  color: colors.tertiary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '在编辑页底部的「标签」按钮里添加',
                                style: TextStyle(
                                  fontSize: AppFontSize.caption,
                                  color: colors.tertiary,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                          itemCount: names.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (BuildContext context, int index) {
                            final String tag = names[index];
                            final int count = counts[tag] ?? 0;
                            return _TagRow(
                              tag: tag,
                              count: count,
                              color: cardColor,
                              onTap: () => _openTag(context, tag),
                              onManage: () =>
                                  _showActions(context, tag, count),
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: Text(
                    '改名、合并、删除都只影响标签本身，不会删除笔记。',
                    style: TextStyle(
                      fontSize: AppFontSize.caption,
                      height: 1.6,
                      color: colors.tertiary,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, AppColors colors) {
    return SizedBox(
      height: 48,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 48,
            child: InkWell(
              onTap: () => Navigator.of(context).maybePop(),
              child: Icon(
                Icons.arrow_back_ios_new,
                size: 18,
                color: colors.secondary,
              ),
            ),
          ),
          Text(
            '标签管理',
            style: AppText.sheetTitle.copyWith(color: colors.text),
          ),
        ],
      ),
    );
  }
}

class _TagRow extends StatelessWidget {
  const _TagRow({
    required this.tag,
    required this.count,
    required this.color,
    required this.onTap,
    required this.onManage,
  });

  final String tag;
  final int count;
  final Color color;

  /// 点行：回首页按该标签筛选。
  final VoidCallback onTap;

  /// 行尾「…」：重命名 / 合并 / 删除。
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(AppRadius.card),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 54,
          padding: const EdgeInsets.only(left: 16, right: 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '#$tag',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: AppFontSize.body, color: colors.text),
                ),
              ),
              Text(
                '$count 条',
                style: TextStyle(fontSize: AppFontSize.value, color: colors.secondary),
              ),
              const SizedBox(width: 6),
              IconButton(
                onPressed: onManage,
                tooltip: '管理标签',
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.more_horiz,
                  size: 20,
                  color: colors.tertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
