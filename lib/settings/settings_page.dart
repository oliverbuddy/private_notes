import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException;

import '../data/note_repository.dart';
import '../data/note_store.dart';
import '../models/note.dart';
import '../models/note_settings.dart';
import '../security/unlock.dart';
import '../theme/app_theme.dart';
import '../ui/show_sheet.dart';
import '../ui/snack.dart';
import '../util/date_format.dart';
import '../util/native_zip.dart';
import 'trash_page.dart';

/// 设置页。
///
/// 两组：外观和数据（导出）。刻意不放「关于」「反馈」「云同步」——
/// 一个本地优先的工具，设置项越少越可信。
/// 主页右上角「···」直达这里，导出收进来作为数据卡片的一行 ——
/// 首页菜单不再单列导出入口。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.repository});

  final NoteRepository repository;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  NoteRepository get repository => widget.repository;

  /// 导出进行中：行内转圈并挡住重复点击。
  ///
  /// 打包在 compute isolate 里跑（不卡 UI），但读全部笔记 + 压缩 +
  /// 拉起系统保存对话框要几秒 —— 没有 loading 时用户会以为没点上
  /// （反复点、退出页面），有转圈才知道「在干活」。
  bool _exporting = false;

  /// 最近一次备份时间（自动/手动/恢复前快照都算）。
  DateTime? _lastBackup;

  /// 「立即备份」进行中：防止重复点击。
  bool _backingUp = false;

  @override
  void initState() {
    super.initState();
    _refreshLastBackup();
  }

  Future<void> _refreshLastBackup() async {
    final time = await repository.lastBackupTime();
    if (mounted) {
      setState(() => _lastBackup = time);
    }
  }

  /// 「立即备份」行的状态文案。
  ///
  /// 自动备份失败时用户无从感知，这里把它摊到设置页上：失败 → 提示重试；
  /// 成功 → 显示最近一次备份时间；从未备份 → 明确说「尚无备份」。
  String _backupStatusText() {
    if (_backingUp) {
      return '备份中…';
    }
    if (repository.lastBackupError != null) {
      return '上次失败，点此重试';
    }
    if (_lastBackup == null) {
      return '尚无备份';
    }
    return '上次 ${formatListTime(_lastBackup!)}';
  }

  /// 「自动导出到文件夹」行的状态文案。
  ///
  /// 外置备份是唯一的「换机/丢失手机也能找回」通道，失败必须显性化，
  /// 否则用户会以为数据已经有第二份了。
  String _externalBackupStatusText() {
    if (repository.externalBackupRunning) {
      return '导出中…';
    }
    if (repository.lastExternalBackupError != null) {
      return '上次失败，点此重试';
    }
    if (repository.settings.externalBackupUri == null) {
      return '未开启';
    }
    final DateTime? at = repository.lastExternalBackupTime;
    return at == null ? '每 24 小时' : '上次 ${formatListTime(at)}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? colors.page : colors.pageAlt,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: repository,
          builder: (BuildContext context, Widget? child) {
            final settings = repository.settings;
            final cardColor = isDark ? colors.pageAlt : colors.page;

            return Column(
              children: <Widget>[
                _buildHeader(context, colors),
                Expanded(
                  // 平板/宽屏上限宽居中，表单拉满全宽没法看
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: ListView(
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                    children: <Widget>[
                      _buildCard(
                        colors: colors,
                        cardColor: cardColor,
                        rows: <Widget>[
                          _SettingRow(
                            label: '主题',
                            value: settings.theme.label,
                            onTap: () => _pickTheme(context, settings),
                          ),
                          _divider(colors),
                          _SettingRow(
                            label: '列表密度',
                            value: settings.density.label,
                            onTap: () => _pickDensity(context, settings),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _buildCard(
                        colors: colors,
                        cardColor: cardColor,
                        rows: <Widget>[
                          _SettingRow(
                            label: '应用锁',
                            value: settings.lockEnabled ? '已开启' : '已关闭',
                            onTap: () => _toggleAppLock(settings),
                          ),
                          if (settings.lockEnabled) ...<Widget>[
                            _divider(colors),
                            _SettingRow(
                              label: '自动锁定',
                              value: _autoLockLabel(settings.autoLockSeconds),
                              onTap: () => _pickAutoLock(settings),
                            ),
                          ],
                          _divider(colors),
                          _SettingRow(
                            label: '锁定内容禁止截屏',
                            value: settings.secureScreen ? '开' : '关',
                            onTap: () => repository.updateSettings(
                              settings.copyWith(
                                secureScreen: !settings.secureScreen,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _buildCard(
                        colors: colors,
                        cardColor: cardColor,
                        rows: <Widget>[
                          // 「备份」是一个动作入口：立即备份（App 内）与备份到
                          // 文件夹（原「导出全部」）产物是同一个 zip，没必要
                          // 在主界面并列成两行 —— 只在需要交出去时多问一步。
                          _SettingRow(
                            label: '备份',
                            value: _backupStatusText(),
                            onTap: _backingUp || _exporting
                                ? null
                                : _openBackupSheet,
                          ),
                          _divider(colors),
                          // 从 zip 恢复：迁移/换机/卸载重装后找回全部笔记。
                          _SettingRow(
                            label: '从备份恢复',
                            value: _restoring ? '恢复中…' : null,
                            onTap: () {
                              if (!_restoring) {
                                _restoreBackup();
                              }
                            },
                          ),
                          _divider(colors),
                          // 外置备份：写进用户授权的文件夹（SD 卡/网盘目录），
                          // 是「手机丢了备份还在」的唯一通道。
                          _SettingRow(
                            label: '自动备份到文件夹',
                            value: _externalBackupStatusText(),
                            onTap: repository.externalBackupRunning
                                ? null
                                : () => _openExternalBackup(),
                          ),
                          _divider(colors),
                          _SettingRow(
                            label: '最近删除',
                            onTap: _openTrash,
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      _buildDataNote(colors),
                    ],
                  ),
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

  /// 底部「数据说明」：四行「小标题 + 一句短句」。
  ///
  /// 原先是一整段 6 行的文字，实际没人读。拆成固定宽度的小标题后，
  /// 用户扫一眼就能找到「存在哪 / 会怎么丢 / 备份怎么运作 / 锁定笔记」，
  /// 核心信息一条不少。
  Widget _buildDataNote(AppColors colors) {
    Widget item(String label, String text) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 56,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  fontWeight: AppWeight.medium,
                  color: colors.secondary,
                ),
              ),
            ),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: colors.tertiary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          item('存放位置', '应用私有目录，系统「文件」管理器看不到，也不随系统云备份上传。'),
          item('卸载风险', '卸载 App 会一并删除，换机前请先「备份到文件夹」。'),
          item('自动备份', '本机每天 1 份；文件夹每 24 小时 1 份，各保留最近 3 份。'),
          item(
            '锁定笔记',
            '密文只在本机可解密；备份到文件夹默认不含锁定笔记与「最近删除」。',
          ),
        ],
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
            '设置',
            style: AppText.sheetTitle.copyWith(color: colors.text),
          ),
        ],
      ),
    );
  }

  Widget _buildCard({
    required AppColors colors,
    required Color cardColor,
    required List<Widget> rows,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(children: rows),
    );
  }

  Widget _divider(AppColors colors) {
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: Container(height: 0.5, color: colors.dividerStrong),
    );
  }

  String _autoLockLabel(int seconds) {
    switch (seconds) {
      case 60:
        return '1 分钟';
      case 300:
        return '5 分钟';
      default:
        return '立即';
    }
  }

  /// 开关应用锁：开启时优先用系统凭证；设备无安全锁屏则要求设置 PIN。
  Future<void> _toggleAppLock(NoteSettings settings) async {
    if (settings.lockEnabled) {
      final bool ok = await verifyIdentity(
        context,
        settings: settings,
        reason: '验证身份后关闭应用锁',
      );
      if (!ok || !mounted) {
        return;
      }
      await repository.updateSettings(settings.copyWith(lockEnabled: false));
      if (mounted) {
        _showSnack('已关闭应用锁');
      }
      return;
    }

    final bool deviceSecure = await kSecurity.isDeviceSecure();
    String? pinHash = settings.pinHash;
    String? pinSalt = settings.pinSalt;
    if (!deviceSecure && pinHash == null) {
      if (!mounted) {
        return;
      }
      final String? pin =
          await promptPinSheet(context, title: '设置应用锁 PIN');
      if (pin == null || !mounted) {
        return;
      }
      try {
        pinSalt = await kSecurity.randomSalt();
        pinHash = await kSecurity.hashPin(pin: pin, salt: pinSalt);
      } catch (error) {
        if (mounted) {
          _showSnack('开启失败：$error');
        }
        return;
      }
    }
    await repository.updateSettings(
      settings.copyWith(
        lockEnabled: true,
        pinHash: pinHash,
        pinSalt: pinSalt,
      ),
    );
    if (mounted) {
      _showSnack(
        deviceSecure
            ? '已开启应用锁：使用系统锁屏验证'
            : '已开启应用锁：使用 PIN 解锁',
      );
    }
  }

  Future<void> _pickAutoLock(NoteSettings settings) async {
    final int? picked = await _pickOption<int>(
      context: context,
      title: '自动锁定',
      options: const <int>[0, 60, 300],
      current: settings.autoLockSeconds,
      labelOf: _autoLockLabel,
    );
    if (picked == null || !mounted) {
      return;
    }
    await repository.updateSettings(settings.copyWith(autoLockSeconds: picked));
  }

  Future<void> _pickTheme(BuildContext context, NoteSettings settings) async {
    final picked = await _pickOption<AppThemeMode>(
      context: context,
      title: '主题',
      options: AppThemeMode.values,
      current: settings.theme,
      labelOf: (AppThemeMode mode) => mode.label,
    );
    if (picked == null) {
      return;
    }
    await repository.updateSettings(settings.copyWith(theme: picked));
  }

  Future<void> _pickDensity(BuildContext context, NoteSettings settings) async {
    final picked = await _pickOption<ListDensity>(
      context: context,
      title: '列表密度',
      options: ListDensity.values,
      current: settings.density,
      labelOf: (ListDensity density) => density.label,
    );
    if (picked == null) {
      return;
    }
    await repository.updateSettings(settings.copyWith(density: picked));
  }

  Future<T?> _pickOption<T>({
    required BuildContext context,
    required String title,
    required List<T> options,
    required T current,
    required String Function(T option) labelOf,
  }) {
    final colors = AppColors.of(context);
    return showXiaojiSheet<T>(
      context: context,
      builder: (BuildContext sheetContext) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
                child: Row(
                  children: <Widget>[
                    Text(
                      title,
                      style: AppText.caption.copyWith(
                        color: colors.tertiary,
                      ),
                    ),
                  ],
                ),
              ),
              for (final option in options)
                InkWell(
                  onTap: () => Navigator.of(sheetContext).pop(option),
                  child: Container(
                    height: 52,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    alignment: Alignment.centerLeft,
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            labelOf(option),
                            style: TextStyle(fontSize: 16, color: colors.text),
                          ),
                        ),
                        if (option == current)
                          Icon(Icons.check, size: 18, color: colors.accent),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  bool _restoring = false;

  /// 「备份」行入口：应用内备份 / 备份到文件夹（原「导出全部」）。
  ///
  /// 两者产物是同一个 zip，区别只在存放位置与锁定笔记的处理方式。
  /// 合并后主界面少一行语义重复的「导出全部」，能力一个不少。
  Future<void> _openBackupSheet() async {
    final String? action = await showXiaojiSheet<String>(
      context: context,
      builder: (BuildContext sheetContext) {
        final AppColors colors = AppColors.of(sheetContext);
        Widget tile({
          required String label,
          required String subtitle,
          required String value,
        }) {
          return InkWell(
            onTap: () => Navigator.of(sheetContext).pop(value),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(fontSize: 16, color: colors.text),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      color: colors.tertiary,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
                  child: Text(
                    '备份',
                    style: AppText.caption.copyWith(color: colors.tertiary),
                  ),
                ),
                tile(
                  label: '立即备份到应用内',
                  subtitle: '含锁定笔记密文，只能在本机恢复',
                  value: 'local',
                ),
                tile(
                  label: '备份到文件夹…',
                  subtitle: '生成 zip 交给系统保存，换机或归档用；可选含锁定笔记明文',
                  value: 'file',
                ),
              ],
            ),
          ),
        );
      },
    );
    if (action == null || !mounted) {
      return;
    }
    if (action == 'local') {
      await _backupNow();
    } else {
      await _exportAll();
    }
  }

  /// 立即生成一份应用私有备份（不进系统相册/云备份）。
  Future<void> _backupNow() async {
    if (_backingUp) {
      return;
    }
    setState(() => _backingUp = true);
    try {
      await repository.createBackupNow();
      await _refreshLastBackup();
      if (!mounted) {
        return;
      }
      _showSnack('已备份到应用私有目录');
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showSnack('备份失败：$error');
    } finally {
      if (mounted) {
        setState(() => _backingUp = false);
      }
    }
  }

  /// 外置备份入口：未开启 → 直接选文件夹；已开启 → 操作菜单。
  Future<void> _openExternalBackup() async {
    if (repository.settings.externalBackupUri == null) {
      await _chooseExternalBackupFolder();
      return;
    }
    final String? action = await _pickExternalAction();
    if (action == null || !mounted) {
      return;
    }
    switch (action) {
      case 'export':
        await _exportToFolder();
        return;
      case 'change':
        await _chooseExternalBackupFolder();
        return;
      case 'off':
        await repository.updateSettings(
          repository.settings.copyWith(clearExternalBackup: true),
        );
        if (mounted) {
          _showSnack('已关闭自动备份');
        }
        return;
    }
  }

  Future<String?> _pickExternalAction() {
    return showXiaojiSheet<String>(
      context: context,
      builder: (BuildContext sheetContext) {
        final AppColors sheetColors = AppColors.of(sheetContext);
        Widget tile({required String label, required String value}) {
          return InkWell(
            onTap: () => Navigator.of(sheetContext).pop(value),
            child: Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              alignment: Alignment.centerLeft,
              child: Text(
                label,
                style: TextStyle(fontSize: 16, color: sheetColors.text),
              ),
            ),
          );
        }

        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '自动备份到文件夹',
                    style: AppText.caption.copyWith(color: sheetColors.tertiary),
                  ),
                ),
              ),
              tile(label: '立即备份', value: 'export'),
              tile(label: '更换文件夹', value: 'change'),
              tile(label: '关闭自动备份', value: 'off'),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// 选择文件夹并立刻导出一次：用户选完就能看到结果，不用再点一次。
  Future<void> _chooseExternalBackupFolder() async {
    String? uri;
    try {
      uri = await pickBackupDirectory();
    } on MissingPluginException {
      _showSnack('当前平台不支持选择文件夹');
      return;
    } catch (error) {
      _showSnack('无法打开文件夹选择器：$error');
      return;
    }
    if (uri == null || !mounted) {
      return; // 用户取消
    }
    await repository.updateSettings(
      repository.settings.copyWith(externalBackupUri: uri),
    );
    await _exportToFolder();
  }

  /// 立即把导出包写进外置目录（强制，忽略 24 小时间隔）。
  Future<void> _exportToFolder() async {
    final DateTime? at = await repository.runExternalBackup(force: true);
    if (!mounted) {
      return;
    }
    if (at != null) {
      _showSnack('已备份到所选文件夹');
      return;
    }
    final String? error = repository.lastExternalBackupError;
    if (error != null) {
      _showSnack('备份失败：$error');
    }
  }

  Future<void> _openTrash() async {
    hideSnack(context);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            TrashPage(repository: repository),
      ),
    );
  }

  /// 「从文件选择」的哨兵值：弹层返回它表示走系统文件选择器。
  static const String _pickFileSentinel = '__pick_file__';

  /// 从备份恢复：先选来源（应用内备份 / 系统文件）→ 确认覆盖 → 执行。
  ///
  /// 应用内备份在私有目录，系统文件管理器看不到，必须在这里列出来 ——
  /// 否则「立即备份」「每日自动备份」永远没有恢复入口。
  Future<void> _restoreBackup() async {
    final String? source = await _pickRestoreSource();
    if (source == null || !mounted) {
      return;
    }

    String? path = source == _pickFileSentinel ? null : source;
    if (source == _pickFileSentinel) {
      // 只取路径，不把 zip 读进内存（大备份会 OOM）。
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['zip'],
        withData: false,
      );
      path = picked?.files.single.path;
      if (!mounted) {
        return;
      }
      if (path == null) {
        if (picked != null) {
          _showSnack('无法读取所选文件');
        }
        return; // 用户取消
      }
    }

    final confirmed = await showXiaojiConfirmSheet(
      context: context,
      title: '从备份恢复？',
      message: '备份里与现有小记同 id 的会被覆盖为备份内容，其余保留。'
          '恢复前会自动留一份当前数据的快照。',
      confirmLabel: '恢复',
    );
    if (confirmed != true || !mounted) {
      return;
    }

    setState(() => _restoring = true);
    try {
      // 恢复是覆盖语义：先强制留一份当前数据，恢复错了还能回滚。
      await repository.store.createPreRestoreSnapshot();
      await _refreshLastBackup();
      final (int restored, int skipped) = await _restoreFromPath(path!);
      if (!mounted) {
        return;
      }
      await _showRestoreResult(restored, skipped);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showSnack('恢复失败：$error');
    } finally {
      if (mounted) {
        setState(() => _restoring = false);
      }
    }
  }

  /// 原生流式恢复；桌面/测试环境没有原生通道时回退到内存版。
  Future<(int, int)> _restoreFromPath(String path) async {
    try {
      return await repository.restoreFromZipFile(path);
    } on MissingPluginException {
      return await repository.restoreFromZip(await File(path).readAsBytes());
    }
  }

  /// 选择恢复来源：应用内备份列表 + 「从文件选择…」。
  Future<String?> _pickRestoreSource() async {
    final backups = await repository.listBackups();
    if (!mounted) {
      return null;
    }
    final colors = AppColors.of(context);
    return showXiaojiSheet<String>(
      context: context,
      builder: (BuildContext sheetContext) {
        final sheetColors = AppColors.of(sheetContext);
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '从备份恢复',
                    style: AppText.caption.copyWith(color: sheetColors.tertiary),
                  ),
                ),
              ),
              if (backups.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '还没有应用内备份，可直接选择导出的 zip 文件。',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: sheetColors.secondary,
                      ),
                    ),
                  ),
                )
              else
                for (final BackupEntry entry in backups)
                  InkWell(
                    onTap: () =>
                        Navigator.of(sheetContext).pop(entry.path),
                    child: Container(
                      height: 56,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: <Widget>[
                          Icon(
                            _backupIcon(entry.kind),
                            size: 18,
                            color: sheetColors.secondary,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  entry.kind.label,
                                  style: TextStyle(
                                    fontSize: 15,
                                    color: sheetColors.text,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  formatListTime(entry.time),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: sheetColors.tertiary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              _divider(colors),
              InkWell(
                onTap: () =>
                    Navigator.of(sheetContext).pop(_pickFileSentinel),
                child: Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  alignment: Alignment.centerLeft,
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.folder_open,
                        size: 18,
                        color: sheetColors.secondary,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '从文件选择…',
                        style: TextStyle(
                          fontSize: 15,
                          color: sheetColors.text,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
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

  Future<void> _showRestoreResult(int restored, int skipped) {
    return showXiaojiSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        final sheetColors = AppColors.of(sheetContext);
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  restored == 0 ? '没有可恢复的内容' : '恢复完成',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: AppWeight.medium,
                    color: sheetColors.text,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  restored == 0
                      // 选错文件（普通 zip / 别的 App 的备份）时不能报「成功」，
                      // 否则用户会以为数据已经回来了。
                      ? '这个文件里没有小记，可能选错了备份。现有笔记没有被改动。'
                      : skipped == 0
                          ? '恢复了 $restored 篇小记和附件。'
                          : '恢复了 $restored 篇小记和附件，$skipped 篇文件损坏已跳过。',
                  style: TextStyle(
                    fontSize: 15,
                    color: sheetColors.secondary,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 导出全部：原生流式打包 → 系统「另存为」。
  ///
  /// 全程不把 zip 读进 Dart 内存：写入 Xiaoji/tmp 的临时文件，再用
  /// SAF 流式复制到用户选的位置；完成后删掉临时文件。
  ///
  /// 有锁定笔记时先问一次：默认排除（密文换机也解不开），
  /// 也可选「包含锁定笔记（明文）」—— 后者必须先验证身份。
  Future<void> _exportAll() async {
    bool includeLocked = false;
    final int lockedCount =
        repository.notes.where((Note note) => note.locked).length;
    if (lockedCount > 0) {
      final bool? include = await _askExportLocked(lockedCount);
      if (include == null || !mounted) {
        return;
      }
      if (include) {
        final bool ok = await verifyIdentity(
          context,
          settings: repository.settings,
          reason: '导出锁定笔记（明文）',
        );
        if (!ok || !mounted) {
          return;
        }
        includeLocked = true;
      }
    }

    setState(() => _exporting = true);
    File? temp;
    try {
      final stamp = formatExportStamp(DateTime.now());
      final name = 'xiaoji-export-$stamp.zip';
      temp = await repository.store.createTempExportFile(name);
      await repository.store.buildExportZipToFile(
        temp.path,
        includeLocked: includeLocked,
      );
      final saved = await saveFileToUser(
        sourcePath: temp.path,
        fileName: name,
      );
      if (!mounted || saved == null) {
        return; // 用户取消
      }
      await _showExportResult('导出文件已保存到：\n$saved');
    } on MissingPluginException {
      // 桌面/测试环境没有原生通道：退回内存版 + FilePicker。
      await _exportWithFilePicker(includeLocked: includeLocked);
    } catch (error) {
      if (!mounted) {
        return;
      }
      _showSnack('导出失败：$error');
    } finally {
      try {
        if (temp != null && await temp.exists()) {
          await temp.delete();
        }
      } catch (_) {
        // 临时文件删不掉不影响导出结果。
      }
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }

  /// 有锁定笔记时的导出选项：默认排除，或明文导出（需另外验证身份）。
  ///
  /// 返回 null = 用户取消；false = 不含锁定笔记；true = 含锁定笔记（明文）。
  Future<bool?> _askExportLocked(int count) {
    return showXiaojiSheet<bool>(
      context: context,
      builder: (BuildContext sheetContext) {
        final AppColors colors = AppColors.of(sheetContext);
        Widget tile({
          required IconData icon,
          required String label,
          required String subtitle,
          required bool value,
        }) {
          return InkWell(
            onTap: () => Navigator.of(sheetContext).pop(value),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(icon, size: 20, color: colors.text),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          label,
                          style: TextStyle(fontSize: 16, color: colors.text),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.5,
                            color: colors.tertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
                  child: Text(
                    '有 $count 篇锁定笔记',
                    style: AppText.caption.copyWith(color: colors.tertiary),
                  ),
                ),
                tile(
                  icon: Icons.lock_outline,
                  label: '导出（不含锁定笔记）',
                  subtitle: '默认。锁定正文是设备加密的，换机后也无法解密。',
                  value: false,
                ),
                tile(
                  icon: Icons.lock_open_outlined,
                  label: '导出（含锁定笔记，明文）',
                  subtitle: '会把锁定正文解密后写进 zip，需要先验证身份。',
                  value: true,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 内存版导出（仅原生通道不可用的桌面/测试环境）。
  ///
  /// 与主通道保持同样的隐私语义：默认排除锁定笔记；这里没有原生解密
  /// 能力，选「明文导出」只能把密文原样带出，并在结果里明确说明。
  Future<void> _exportWithFilePicker({required bool includeLocked}) async {
    try {
      final excludeIds = includeLocked
          ? const <String>{}
          : repository.notes
              .where((Note note) => note.locked)
              .map((Note note) => note.id)
              .toSet();
      final data = await repository.store.buildExportZip(
        excludeNoteIds: excludeIds,
      );
      final stamp = formatExportStamp(DateTime.now());
      final saved = await FilePicker.platform.saveFile(
        fileName: 'xiaoji-export-$stamp.zip',
        type: FileType.custom,
        allowedExtensions: <String>['zip'],
        bytes: data,
      );
      if (!mounted || saved == null) {
        return;
      }
      await _showExportResult(
        '导出文件已保存到：\n$saved'
        '${includeLocked ? '\n\n当前环境不支持解密，锁定笔记以密文保留。' : ''}',
      );
    } catch (error) {
      if (mounted) {
        _showSnack('导出失败：$error');
      }
    }
  }

  Future<void> _showExportResult(String message) {
    return showXiaojiSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) =>
          _ExportResultSheet(message: message),
    );
  }

  void _showSnack(String text) {
    showSnack(
      context,
      message: text,
      duration: const Duration(seconds: 3),
    );
  }
}

/// 备份结果弹层：标题 + 多行说明 + 单个「好」按钮。
class _ExportResultSheet extends StatelessWidget {
  const _ExportResultSheet({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '备份文件已保存',
              style: AppText.sheetTitle.copyWith(color: colors.text),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.7,
                color: colors.secondary,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(
                  backgroundColor: colors.surface2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(
                  '好',
                  style: TextStyle(
                    fontSize: 16,
                    height: 1,
                    fontWeight: AppWeight.medium,
                    color: colors.accent,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({required this.label, this.value, required this.onTap});

  final String label;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.centerLeft,
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: 16, color: colors.text),
              ),
            ),
            if (value != null)
              Text(
                value!,
                style: TextStyle(fontSize: 14, color: colors.secondary),
              ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right, size: 18, color: colors.tertiary),
          ],
        ),
      ),
    );
  }
}
