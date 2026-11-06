import 'package:flutter/material.dart';

import '../data/note_store.dart';
import '../theme/app_theme.dart';
import '../ui/show_sheet.dart';
import '../util/date_format.dart';

/// 「备份与恢复」弹层里可以触发的动作。
///
/// 弹层只负责呈现和选择，真正的备份/恢复逻辑仍留在 [SettingsPage]，
/// 避免 UI 与数据操作耦合（后续上平板/桌面端时，弹层可以换成对话框，
/// 动作定义不用动）。
enum BackupAction {
  /// 开启「自动备份到文件夹」（需要选择目录）。
  enableAuto,

  /// 关闭「自动备份到文件夹」。
  disableAuto,

  /// 更换已选的备份文件夹。
  changeFolder,

  /// 立即备份到应用内。
  backupNow,

  /// 导出 zip（换机 / 归档）。
  exportZip,

  /// 从备份恢复。
  restore,
}

/// 恢复来源里「从文件选择」的哨兵值。
const String pickBackupFileSentinel = '__pick_backup_file__';

/// 把 SAF 树 URI 解析成用户看得懂的文件夹名。
///
/// `content://…/tree/primary%3ADownload%2FXiaoji` → `Download/Xiaoji`。
/// 解析失败时给一个中性文案，绝不把长 URI 直接摊到界面上。
String backupFolderLabel(String? treeUri) {
  if (treeUri == null || treeUri.isEmpty) {
    return '未选择';
  }
  try {
    final String decoded = Uri.decodeComponent(treeUri);
    final String tail = decoded.split(':').last;
    // `primary:Download/Xiaoji` 里的卷名在冒号前，冒号后就是用户选的路径，
    // 所以这里原样拼回去即可（例如 `Download/Xiaoji`）。
    final List<String> parts =
        tail.split('/').where((String item) => item.isNotEmpty).toList();
    if (parts.isEmpty) {
      return '已选择';
    }
    return parts.join('/');
  } catch (_) {
    return '已选择';
  }
}

/// 「备份与恢复」总入口。
///
/// 设计对齐主流笔记 App（滴答清单的「备份与还原」、Bear/Joplin 的
/// 自动备份设置）：只保留一个入口，内部把「自动备份」做成开关，
/// 手动动作按用户意图命名（立即备份 / 导出 zip / 从备份恢复），
/// 不再把「备份」和「自动备份到文件夹」并排成两个看起来差不多的按钮。
Future<BackupAction?> showBackupMenu(
  BuildContext context, {
  required bool autoEnabled,
  required bool autoBusy,
  required String autoStatusLabel,
  required String folderLabel,
  required String lastBackupLabel,
}) {
  return showXiaojiSheet<BackupAction>(
    context: context,
    builder: (BuildContext sheetContext) {
      final AppColors colors = AppColors.of(sheetContext);

      String autoSubtitle() {
        if (!autoEnabled) {
          return '关闭时仍每天备份到应用内（保留最近 3 份）';
        }
        return '文件夹：$folderLabel · $autoStatusLabel';
      }

      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 2),
              child: Text(
                '备份与恢复',
                style: AppText.sheetTitle.copyWith(color: colors.text),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                lastBackupLabel,
                style: TextStyle(
                  fontSize: AppFontSize.meta,
                  height: 1.5,
                  color: colors.tertiary,
                ),
              ),
            ),
            _SwitchRow(
              title: '自动备份到文件夹',
              subtitle: autoSubtitle(),
              value: autoEnabled,
              enabled: !autoBusy,
              onChanged: () => Navigator.of(sheetContext).pop(
                autoEnabled ? BackupAction.disableAuto : BackupAction.enableAuto,
              ),
            ),
            if (autoEnabled)
              _ActionRow(
                label: '更换文件夹',
                subtitle: '当前：$folderLabel',
                onTap: () =>
                    Navigator.of(sheetContext).pop(BackupAction.changeFolder),
              ),
            _Hairline(colors: colors),
            _ActionRow(
              label: '立即备份',
              subtitle: '存到应用内，含锁定笔记密文（只能在本机恢复）',
              onTap: () =>
                  Navigator.of(sheetContext).pop(BackupAction.backupNow),
            ),
            _ActionRow(
              label: '导出 zip（换机 / 归档）…',
              subtitle: '另存为文件，可包含锁定笔记明文',
              onTap: () =>
                  Navigator.of(sheetContext).pop(BackupAction.exportZip),
            ),
            _ActionRow(
              label: '从备份恢复',
              subtitle: '合并恢复，不会删除现有笔记',
              onTap: () => Navigator.of(sheetContext).pop(BackupAction.restore),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

/// 「从备份恢复」的来源选择。
///
/// 返回备份文件路径；[pickBackupFileSentinel] 表示走系统文件选择；
/// null 表示用户取消。
Future<String?> showRestoreSourceMenu(
  BuildContext context, {
  required List<BackupEntry> backups,
}) {
  return showXiaojiSheet<String>(
    context: context,
    builder: (BuildContext sheetContext) {
      final AppColors colors = AppColors.of(sheetContext);
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 2),
              child: Text(
                '从备份恢复',
                style: AppText.sheetTitle.copyWith(color: colors.text),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                '恢复是合并覆盖：同一条笔记以备份为准，其它笔记保留。'
                '恢复前会自动留一份当前数据的快照。',
                style: TextStyle(
                  fontSize: AppFontSize.meta,
                  height: 1.6,
                  color: colors.tertiary,
                ),
              ),
            ),
            if (backups.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  '还没有应用内备份，可以从文件选择一份 zip。',
                  style: TextStyle(
                    fontSize: AppFontSize.label,
                    height: 1.5,
                    color: colors.secondary,
                  ),
                ),
              )
            else
              for (final BackupEntry entry in backups)
                _BackupEntryRow(
                  entry: entry,
                  onTap: () => Navigator.of(sheetContext).pop(entry.path),
                ),
            _Hairline(colors: colors),
            _ActionRow(
              icon: Icons.folder_open,
              label: '从 zip 文件选择…',
              onTap: () => Navigator.of(sheetContext)
                  .pop(pickBackupFileSentinel),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}

/// 开关行：整行可点，右侧是标准开关。
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return InkWell(
      onTap: enabled ? onChanged : null,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: AppFontSize.body,
                      color: enabled ? colors.text : colors.tertiary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: AppFontSize.caption,
                      height: 1.5,
                      color: colors.tertiary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Switch(
              value: value,
              onChanged: enabled ? (_) => onChanged() : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// 动作行：标题 + 可选副标题 + 右侧箭头。
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.label,
    required this.onTap,
    this.subtitle,
    this.icon,
  });

  final String label;
  final String? subtitle;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 11, 16, 11),
        child: Row(
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 18, color: colors.secondary),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(fontSize: AppFontSize.body, color: colors.text),
                  ),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: AppFontSize.caption,
                        height: 1.5,
                        color: colors.tertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: colors.tertiary),
          ],
        ),
      ),
    );
  }
}

/// 备份列表里的一条：时间为主、类型为辅。
class _BackupEntryRow extends StatelessWidget {
  const _BackupEntryRow({required this.entry, required this.onTap});

  final BackupEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
        child: Row(
          children: <Widget>[
            Icon(_backupIcon(entry.kind), size: 18, color: colors.secondary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    formatListTime(entry.time),
                    style: TextStyle(fontSize: AppFontSize.summary, color: colors.text),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.kind.label,
                    style: TextStyle(fontSize: AppFontSize.caption, color: colors.tertiary),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: colors.tertiary),
          ],
        ),
      ),
    );
  }

  IconData _backupIcon(BackupKind kind) {
    switch (kind) {
      case BackupKind.auto:
        return Icons.schedule;
      case BackupKind.manual:
        return Icons.save_alt;
      case BackupKind.preRestore:
        return Icons.history;
    }
  }
}

class _Hairline extends StatelessWidget {
  const _Hairline({required this.colors});

  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 0.5,
      margin: const EdgeInsets.only(left: 20),
      color: colors.dividerStrong,
    );
  }
}
