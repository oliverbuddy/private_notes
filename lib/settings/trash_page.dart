import 'package:flutter/material.dart';

import '../data/note_repository.dart';
import '../data/note_store.dart';
import '../theme/app_theme.dart';
import '../ui/action_sheet.dart';
import '../ui/show_sheet.dart';
import '../ui/snack.dart';
import '../util/date_format.dart';

/// 「最近删除」：删除后的正文与附件都在这里，可恢复或彻底删除。
///
/// 保留 30 天，超期由启动时的清理任务自动移除；页面底部常驻说明，
/// 用户不用去猜「删了还能不能找回来」。
class TrashPage extends StatefulWidget {
  const TrashPage({super.key, required this.repository});

  final NoteRepository repository;

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  List<TrashedNote> _entries = const <TrashedNote>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final entries = await widget.repository.loadTrash();
    if (!mounted) {
      return;
    }
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _showActions(TrashedNote entry) async {
    final String? action = await showXiaojiActionSheet<String>(
      context: context,
      title: entry.title.isEmpty ? '这条小记' : entry.title,
      actions: <SheetAction<String>>[
        const SheetAction<String>(
          value: 'restore',
          label: '恢复',
          icon: Icons.restore_rounded,
        ),
        const SheetAction<String>(
          value: 'purge',
          label: '彻底删除',
          icon: Icons.delete_forever_outlined,
          destructive: true,
        ),
      ],
    );
    if (!mounted || action == null) {
      return;
    }
    if (action == 'restore') {
      await _restore(entry);
    } else if (action == 'purge') {
      await _purge(entry);
    }
  }

  Future<void> _restore(TrashedNote entry) async {
    final restored = await widget.repository.restoreFromTrash(entry);
    if (!mounted) {
      return;
    }
    showSnack(
      context,
      message: restored == null ? '恢复失败：文件已损坏' : '已恢复这条小记',
    );
    await _reload();
  }

  Future<void> _purge(TrashedNote entry) async {
    final confirmed = await showXiaojiConfirmSheet(
      context: context,
      title: '彻底删除？',
      message: '正文和附件都会被永久删除，无法恢复。',
      confirmLabel: '彻底删除',
      destructive: true,
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await widget.repository.purgeTrash(entry);
    await _reload();
  }

  Future<void> _clearAll() async {
    final confirmed = await showXiaojiConfirmSheet(
      context: context,
      title: '清空最近删除？',
      message: '${_entries.length} 条小记的正文和附件都会被永久删除。',
      confirmLabel: '清空',
      destructive: true,
    );
    if (confirmed != true || !mounted) {
      return;
    }
    await widget.repository.purgeAllTrash();
    await _reload();
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
        child: Column(
          children: <Widget>[
            _buildHeader(colors),
            Expanded(
              child: _loading
                  ? const SizedBox.shrink()
                  : _entries.isEmpty
                      ? _buildEmpty(colors)
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                          itemCount: _entries.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (BuildContext context, int index) {
                            return _TrashTile(
                              entry: _entries[index],
                              color: cardColor,
                              onTap: () => _showActions(_entries[index]),
                              onRestore: () => _restore(_entries[index]),
                            );
                          },
                        ),
            ),
            if (_entries.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text(
                  '删除的小记会保留 30 天，到期自动清理。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: colors.tertiary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(AppColors colors) {
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
            '最近删除',
            style: AppText.sheetTitle.copyWith(color: colors.text),
          ),
          const Spacer(),
          if (_entries.isNotEmpty)
            TextButton(
              onPressed: _clearAll,
              child: Text(
                '清空',
                style: TextStyle(fontSize: 14, color: colors.danger),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmpty(AppColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.delete_outline, size: 40, color: colors.tertiary),
          const SizedBox(height: 12),
          Text(
            '回收站是空的',
            style: TextStyle(fontSize: 15, color: colors.secondary),
          ),
        ],
      ),
    );
  }
}

class _TrashTile extends StatelessWidget {
  const _TrashTile({
    required this.entry,
    required this.color,
    required this.onTap,
    required this.onRestore,
  });

  final TrashedNote entry;
  final Color color;
  final VoidCallback onTap;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final title = entry.locked
        ? '已锁定'
        : (entry.title.isEmpty ? '（无内容）' : entry.title);
    final detail = <String>[
      formatListTime(entry.deletedAt),
      if (entry.legacyFile)
        '附件已丢失'
      else if (entry.hasAssets)
        '含附件',
    ].join(' · ');

    return Material(
      color: color,
      borderRadius: BorderRadius.circular(AppRadius.card),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        if (entry.locked) ...<Widget>[
                          Icon(Icons.lock_outline,
                              size: 15, color: colors.tertiary),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15.5,
                              height: 1.3,
                              fontWeight: AppWeight.medium,
                              color: entry.locked
                                  ? colors.secondary
                                  : colors.text,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.3,
                        color: colors.tertiary,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: onRestore,
                child: Text(
                  '恢复',
                  style: TextStyle(fontSize: 14, color: colors.accent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
