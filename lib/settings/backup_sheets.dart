import 'package:flutter/material.dart';

import '../data/note_store.dart';
import '../theme/app_theme.dart';
import '../ui/app_field.dart';
import '../ui/pressable.dart';
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

  /// 开启 / 关闭「外置备份口令加密」。
  toggleEncrypt,

  /// 立即备份到应用内。
  backupNow,

  /// 导出 zip（换机 / 归档）。
  exportZip,

  /// 从备份恢复。
  restore,

  /// 导入外部 Markdown 文件（一次性、低频，和恢复同属「把外部数据拿进来」）。
  importMarkdown,
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
    // 桌面端存的是普通文件系统路径（含盘符或 / 开头），
    // 路径可能很长，只显示末两级，避免把设置页的行撑开。
    final bool looksLikePath = treeUri.startsWith('/') ||
        treeUri.contains('\\') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(treeUri);
    if (looksLikePath) {
      final List<String> segments = tail
          .split(RegExp(r'[\\/]'))
          .where((String item) => item.isNotEmpty)
          .toList();
      if (segments.isEmpty) {
        return '已选择';
      }
      if (segments.length <= 2) {
        return segments.join('/');
      }
      return '…/${segments.sublist(segments.length - 2).join('/')}';
    }
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
  required bool encrypted,
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
              padding: const EdgeInsets.fromLTRB(16, 6, 20, 2),
              child: Text(
                '备份与恢复',
                style: AppText.sheetTitle.copyWith(color: colors.text),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 20, 8),
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
                autoEnabled
                    ? BackupAction.disableAuto
                    : BackupAction.enableAuto,
              ),
            ),
            if (autoEnabled)
              _ActionRow(
                label: '更换文件夹',
                subtitle: '当前：$folderLabel',
                onTap: () =>
                    Navigator.of(sheetContext).pop(BackupAction.changeFolder),
              ),
            if (autoEnabled)
              _SwitchRow(
                title: '加密外置备份',
                subtitle: encrypted
                    ? '已开启：备份包用口令加密，恢复时需要输入口令'
                    : '关闭时备份包是明文 zip，网盘同步时会原样上传',
                value: encrypted,
                enabled: !autoBusy,
                onChanged: () => Navigator.of(sheetContext)
                    .pop(BackupAction.toggleEncrypt),
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
              subtitle: '按备份条目回到快照，备份外的笔记不受影响',
              onTap: () => Navigator.of(sheetContext).pop(BackupAction.restore),
            ),
            _ActionRow(
              label: '导入 Markdown 文件…',
              subtitle: '从其它 App 导入 .md，图片不随文件搬运',
              onTap: () =>
                  Navigator.of(sheetContext).pop(BackupAction.importMarkdown),
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
              padding: const EdgeInsets.fromLTRB(16, 6, 20, 2),
              child: Text(
                '从备份恢复',
                style: AppText.sheetTitle.copyWith(color: colors.text),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 20, 12),
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
                padding: const EdgeInsets.fromLTRB(16, 0, 20, 12),
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
              icon: Icons.folder_open_rounded,
              label: '从 zip 文件选择…',
              onTap: () =>
                  Navigator.of(sheetContext).pop(pickBackupFileSentinel),
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
    return AppPressable(
      onTap: enabled ? onChanged : null,
      pressedScale: 1,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
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
    return AppPressable(
      onTap: onTap,
      pressedScale: 1,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 11, 16, 11),
        child: Row(
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: AppIcon.nav, color: colors.secondary),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(
                        fontSize: AppFontSize.summary, color: colors.text),
                  ),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: 2),
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
            Icon(Icons.chevron_right_rounded,
                size: AppIcon.chevron, color: colors.tertiary),
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
    return AppPressable(
      onTap: onTap,
      pressedScale: 1,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(
          children: <Widget>[
            Icon(_backupIcon(entry.kind),
                size: AppIcon.nav, color: colors.secondary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    formatListTime(entry.time),
                    style: TextStyle(
                        fontSize: AppFontSize.summary, color: colors.text),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.kind.label,
                    style: TextStyle(
                        fontSize: AppFontSize.caption, color: colors.tertiary),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: AppIcon.chevron, color: colors.tertiary),
          ],
        ),
      ),
    );
  }

  IconData _backupIcon(BackupKind kind) {
    switch (kind) {
      case BackupKind.auto:
        return Icons.schedule_outlined;
      case BackupKind.manual:
        return Icons.save_alt_outlined;
      case BackupKind.preRestore:
        return Icons.history_outlined;
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

/// 备份口令输入弹层。
///
/// [creating] 为 true 时输入两次（设置新口令），false 时输入一次（恢复）。
/// 口令只在内存里交给原生加密，不写入任何文件；外置备份需要的副本
/// 由 Keystore 封存（见 NoteSettings.backupPasswordSealed）。
/// 返回 null 表示用户取消。
Future<String?> showBackupPasswordSheet(
  BuildContext context, {
  required bool creating,
}) {
  return showXiaojiSheet<String>(
    context: context,
    builder: (BuildContext sheetContext) =>
        _BackupPasswordSheet(creating: creating),
  );
}

class _BackupPasswordSheet extends StatefulWidget {
  const _BackupPasswordSheet({required this.creating});

  final bool creating;

  @override
  State<_BackupPasswordSheet> createState() => _BackupPasswordSheetState();
}

class _BackupPasswordSheetState extends State<_BackupPasswordSheet> {
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    final String password = _password.text.trim();
    if (password.length < 6) {
      setState(() => _error = '口令至少 6 位');
      return;
    }
    if (widget.creating && password != _confirm.text.trim()) {
      setState(() => _error = '两次输入不一致');
      return;
    }
    Navigator.of(context).pop(password);
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final double keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 4, 20, 16 + keyboard),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              widget.creating ? '设置备份口令' : '输入备份口令',
              style: AppText.sheetTitle.copyWith(color: colors.text),
            ),
            const SizedBox(height: 6),
            Text(
              widget.creating
                  ? '备份包会用这个口令加密（AES-256）。口令不会存明文，'
                      '忘记后这份备份将无法恢复。'
                  : '这份备份是口令加密的，输入当时设置的口令。',
              style: TextStyle(
                fontSize: AppFontSize.meta,
                height: 1.6,
                color: colors.tertiary,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              autofocus: true,
              obscureText: true,
              textInputAction: widget.creating
                  ? TextInputAction.next
                  : TextInputAction.done,
              onSubmitted: widget.creating ? null : (_) => _submit(),
              style: TextStyle(fontSize: AppFontSize.body, color: colors.text),
              decoration: appFieldDecoration(context, hintText: '备份口令'),
            ),
            if (widget.creating) ...<Widget>[
              const SizedBox(height: 10),
              TextField(
                controller: _confirm,
                obscureText: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                style:
                    TextStyle(fontSize: AppFontSize.body, color: colors.text),
                decoration: appFieldDecoration(context, hintText: '再次输入口令'),
              ),
            ],
            if (_error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(
                  fontSize: AppFontSize.caption,
                  color: colors.danger,
                ),
              ),
            ],
            const SizedBox(height: 16),
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
                    label: widget.creating ? '确定' : '解密',
                    background: colors.surface2,
                    foreground: colors.accent,
                    onTap: _submit,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
