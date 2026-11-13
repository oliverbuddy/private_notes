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
import '../ui/app_icon_button.dart';
import '../ui/app_list.dart';
import '../ui/content_frame.dart';
import '../ui/pressable.dart';
import '../ui/show_sheet.dart';
import '../ui/snack.dart';
import '../util/app_info.dart';
import '../util/date_format.dart';
import '../util/native_zip.dart';
import 'about_page.dart';
import 'backup_sheets.dart';
import 'tags_page.dart';
import 'trash_page.dart';

/// 设置页。
///
/// 三组：外观、安全、数据，底部一个「关于」入口。不做云同步入口 —— 本地优先。
/// 数据卡片只保留「备份与恢复」「回收站」「标签管理」「数据与隐私」四行：
/// 备份的自动/手动/导出全部收进弹层，避免主界面出现多个看起来差不多的入口。
/// 版本、许可、联系方式属于低频信息，收进独立的关于页，不打断分组节奏。
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.repository,
    this.openBackupOnStart = false,
  });

  final NoteRepository repository;

  /// 从主页「数据只存在本机」提示进来时为 true：首帧后直接展开备份菜单。
  final bool openBackupOnStart;

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

  /// 版本信息（从已安装的 APK 读取，异步拿，拿不到时显示占位符）。
  AppInfo? _appInfo;

  /// 存储占用（异步统计；null 表示还没算出来）。
  StorageUsage? _storage;

  /// 「清理未使用附件」进行中：防止重复点击。
  bool _cleaningAssets = false;

  /// 导入 Markdown 进行中：防止重复触发文件选择。
  bool _importingMarkdown = false;

  /// 清理结果的一行反馈（显示在存储弹层里，避免被弹层挡住 SnackBar）。
  String? _storageHint;

  @override
  void initState() {
    super.initState();
    _refreshLastBackup();
    _loadAppInfo();
    _loadStorage();
    if (widget.openBackupOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _openBackupMenu();
        }
      });
    }
  }

  Future<void> _loadAppInfo() async {
    final AppInfo? info = await loadAppInfo();
    if (mounted) {
      setState(() => _appInfo = info);
    }
  }

  Future<void> _refreshLastBackup() async {
    final time = await repository.lastBackupTime();
    if (mounted) {
      setState(() => _lastBackup = time);
    }
  }

  /// 统计各目录占用。失败时保持上一次的数据，不影响其它设置项。
  Future<void> _loadStorage() async {
    try {
      final StorageUsage usage = await repository.measureStorage();
      if (mounted) {
        setState(() => _storage = usage);
      }
    } catch (_) {
      // 忽略：目录被占用 / 权限异常时只是数字不准。
    }
  }

  String? _storageLabel() {
    final StorageUsage? usage = _storage;
    if (usage == null) {
      return '统计中…';
    }
    return '附件 ${_formatBytes(usage.assets)} · 回收站 '
        '${_formatBytes(usage.trash)}';
  }

  /// 「存储空间」弹层：看分类占用 + 清理未引用附件。
  Future<void> _openStorage() async {
    _storageHint = null;
    await _loadStorage();
    if (!mounted) {
      return;
    }
    final StorageUsage? initial = _storage;
    if (initial == null) {
      _showSnack('暂时无法统计存储空间');
      return;
    }
    await showXiaojiSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setSheetState) {
            final AppColors colors = AppColors.of(context);
            final StorageUsage usage = _storage ?? initial;
            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                      child: Text(
                        '存储空间',
                        style: AppText.sheetTitle.copyWith(color: colors.text),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                      child: Text(
                        '合计 ${_formatBytes(usage.total)}',
                        style: AppText.caption.copyWith(color: colors.tertiary),
                      ),
                    ),
                    const SizedBox(height: 12),
                    AppListSection(
                      children: <Widget>[
                        AppListRow(
                          label: '笔记正文',
                          value: _formatBytes(usage.notes),
                        ),
                        AppListRow(
                          label: '附件与图片',
                          value: _formatBytes(usage.assets),
                        ),
                        AppListRow(
                          label: '回收站',
                          value: _formatBytes(usage.trash),
                        ),
                        AppListRow(
                          label: '历史版本',
                          value: _formatBytes(usage.versions),
                        ),
                        AppListRow(
                          label: '备份',
                          value: _formatBytes(usage.backups),
                        ),
                        AppListRow(
                          label: '搜索索引',
                          value: _formatBytes(usage.index),
                        ),
                      ],
                    ),
                    Padding(
                      padding:
                          const EdgeInsets.fromLTRB(AppSpace.lg, 12, AppSpace.lg, 0),
                      child: Text(
                        '附件是正文里引用的图片与文件。回收站内容保留 30 天，到期自动释放。',
                        style: AppText.caption.copyWith(color: colors.tertiary),
                      ),
                    ),
                    if (_storageHint != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                            AppSpace.lg, 8, AppSpace.lg, 0),
                        child: Text(
                          _storageHint!,
                          style:
                              AppText.caption.copyWith(color: colors.accent),
                        ),
                      ),
                    const SizedBox(height: 16),
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                      child: AppSheetButton(
                        label: _cleaningAssets ? '清理中…' : '清理未使用附件',
                        background: colors.accent,
                        foreground: colors.page,
                        onTap: () async {
                          if (_cleaningAssets) {
                            return;
                          }
                          final bool updated = await _cleanUnusedAssets();
                          if (updated && context.mounted) {
                            setSheetState(() {});
                          }
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                      child: AppSheetButton(
                        label: '关闭',
                        background: colors.surface2,
                        foreground: colors.secondary,
                        onTap: () => Navigator.of(sheetContext).pop(),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 执行清理；返回 true 表示弹层里的数字需要刷新。
  Future<bool> _cleanUnusedAssets() async {
    final bool? confirmed = await showXiaojiConfirmSheet(
      context: context,
      title: '清理未使用附件？',
      message: '只删除没有任何笔记（含历史版本）引用的图片与文件。'
          '锁定笔记和回收站里的内容不会被清理。',
      confirmLabel: '清理',
    );
    if (confirmed != true || !mounted) {
      return false;
    }
    setState(() {
      _cleaningAssets = true;
      _storageHint = null;
    });
    try {
      final OrphanCleanupResult result = await repository.cleanUnusedAssets();
      await _loadStorage();
      if (!mounted) {
        return false;
      }
      final StringBuffer hint = StringBuffer();
      if (result.isEmpty) {
        hint.write('没有需要清理的附件');
      } else {
        hint.write('已清理 ${result.files} 个文件，释放 '
            '${_formatBytes(result.bytes)}');
      }
      if (result.lockedSkipped > 0) {
        hint.write('；跳过 ${result.lockedSkipped} 个锁定笔记目录');
      }
      setState(() => _storageHint = hint.toString());
      return true;
    } catch (error) {
      if (mounted) {
        setState(() => _storageHint = '清理失败：$error');
      }
      return true;
    } finally {
      if (mounted) {
        setState(() => _cleaningAssets = false);
      }
    }
  }

  /// 从系统文件选择器导入外部 `.md`。
  ///
  /// 只读文本：Android 10+ 走 SAF 返回的临时副本，不需要申请存储权限。
  Future<void> _importMarkdown() async {
    if (_importingMarkdown) {
      return;
    }
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: <String>['md', 'markdown', 'txt'],
      );
    } on MissingPluginException {
      _showSnack('当前平台不支持选择文件');
      return;
    } catch (error) {
      _showSnack('无法打开文件选择器：$error');
      return;
    }
    if (picked == null || !mounted) {
      return;
    }
    final List<String> paths = <String>[
      for (final PlatformFile file in picked.files)
        if (file.path != null && file.path!.isNotEmpty) file.path!,
    ];
    if (paths.isEmpty) {
      _showSnack('没有读取到可用文件');
      return;
    }
    setState(() => _importingMarkdown = true);
    try {
      final MarkdownImportResult result =
          await repository.importMarkdownFiles(paths);
      await _loadStorage();
      if (!mounted) {
        return;
      }
      final List<String> parts = <String>['已导入 ${result.imported} 篇'];
      if (result.renamed > 0) {
        parts.add('${result.renamed} 篇因 id 重复新建');
      }
      if (result.skipped > 0) {
        parts.add('跳过 ${result.skipped} 个');
      }
      _showSnack('${parts.join('，')}；文内图片不会自动导入');
    } catch (error) {
      if (mounted) {
        _showSnack('导入失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _importingMarkdown = false);
      }
    }
  }

  /// 「备份与恢复」行的状态文案。
  ///
  /// 自动备份失败时用户无从感知，这里把它摊到设置页上：失败 → 提示重试；
  /// 成功 → 显示最近一次备份时间；从未备份 → 明确说「尚无备份」。
  String _backupOverviewText() {
    if (_backingUp || _exporting) {
      return '备份中…';
    }
    if (_restoring) {
      return '恢复中…';
    }
    if (repository.lastBackupError != null) {
      return '上次失败';
    }
    if (_lastBackup == null) {
      return '尚无备份';
    }
    return '上次 ${formatListTime(_lastBackup!)}';
  }

  /// 弹层里的自动备份状态：开启时显示最近一次成功时间或失败原因。
  String _autoBackupStatusText() {
    if (repository.externalBackupRunning) {
      return '备份中…';
    }
    if (repository.lastExternalBackupError != null) {
      return '上次失败';
    }
    final DateTime? at = repository.lastExternalBackupTime;
    return at == null ? '尚未备份' : '上次 ${formatListTime(at)}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);

    return Scaffold(
      backgroundColor: colors.pageAlt,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: repository,
          builder: (BuildContext context, Widget? child) {
            final settings = repository.settings;

            return Column(
              children: <Widget>[
                _buildHeader(context, colors),
                Expanded(
                  // 平板/宽屏上限宽居中（统一走 ContentFrame）
                  child: ContentFrame(
                    child: ListView(
                      physics: const BouncingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                      padding: const EdgeInsets.fromLTRB(
                        AppSpace.page,
                        8,
                        AppSpace.page,
                        32,
                      ),
                      children: <Widget>[
                        AppListSection(
                          header: '外观',
                          children: <Widget>[
                            AppListRow(
                              label: '主题',
                              value: settings.theme.label,
                              chevron: true,
                              onTap: () => _pickTheme(context, settings),
                            ),
                            AppListRow(
                              label: '列表密度',
                              value: settings.density.label,
                              chevron: true,
                              onTap: () => _pickDensity(context, settings),
                            ),
                            AppListRow(
                              label: '排序方式',
                              value: settings.sortOrder.label,
                              chevron: true,
                              onTap: () => _pickSortOrder(context, settings),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        AppListSection(
                          header: '安全',
                          children: <Widget>[
                            AppListRow(
                              label: '应用锁',
                              value: settings.lockEnabled ? '已开启' : '已关闭',
                              chevron: true,
                              onTap: () => _toggleAppLock(settings),
                            ),
                            if (settings.lockEnabled)
                              AppListRow(
                                label: '自动锁定',
                                value: _autoLockLabel(settings.autoLockSeconds),
                                chevron: true,
                                onTap: () => _pickAutoLock(settings),
                              ),
                            AppListRow(
                              label: '锁定内容禁止截屏',
                              value: settings.secureScreen ? '开' : '关',
                              chevron: true,
                              onTap: () => repository.updateSettings(
                                settings.copyWith(
                                  secureScreen: !settings.secureScreen,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        AppListSection(
                          header: '数据',
                          children: <Widget>[
                            // 一个入口收口全部备份能力：自动备份是开关，
                            // 立即备份 / 导出 / 恢复是动作，都在弹层里区分。
                            AppListRow(
                              label: '备份与恢复',
                              value: _backupOverviewText(),
                              chevron: true,
                              onTap: _openBackupMenu,
                            ),
                            AppListRow(
                              label: '回收站',
                              chevron: true,
                              onTap: _openTrash,
                            ),
                            // 存储只做「看」和「清」：不引入数据库维护、
                            // 不做容量上限，避免和本地文件的直觉冲突。
                            AppListRow(
                              label: '存储空间',
                              value: _storageLabel(),
                              chevron: true,
                              onTap: _openStorage,
                            ),
                            AppListRow(
                              label: '导入 Markdown',
                              value: _importingMarkdown ? '导入中…' : null,
                              chevron: true,
                              onTap: _importMarkdown,
                            ),
                            AppListRow(
                              label: '标签管理',
                              chevron: true,
                              onTap: _openTags,
                            ),
                            AppListRow(
                              label: '数据与隐私',
                              chevron: true,
                              onTap: _openDataPrivacy,
                            ),
                          ],
                        ),
                        // 兜底卡片：与上面带标题的分组保持同等呼吸。
                        const SizedBox(height: 24),
                        AppListSection(
                          children: <Widget>[
                            AppListRow(
                              label: '关于',
                              value: _appInfo?.displayVersion,
                              chevron: true,
                              onTap: _openAbout,
                            ),
                          ],
                        ),
                        // 底部留白：说明已收进「数据与隐私」，页面不再堆弱文字。
                        const SizedBox(height: 32),
                      ],
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

  Future<void> _openAbout() async {
    hideSnack(context);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const AboutPage(),
      ),
    );
  }

  /// 数据与隐私说明弹层。
  ///
  /// 每条改成「图标 + 标题 + 一句说明」的纵向信息块：比原来的
  /// 「固定 60dp 小标题 + 右侧小字」更容易扫读，也更有呼吸。
  Future<void> _openDataPrivacy() async {
    hideSnack(context);
    await showXiaojiSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        final AppColors colors = AppColors.of(sheetContext);
        Widget item(IconData icon, String title, String text) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: colors.surface2,
                    borderRadius: BorderRadius.circular(AppRadius.block),
                  ),
                  child:
                      Icon(icon, size: AppIcon.inline, color: colors.secondary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: AppFontSize.summary,
                          height: 1.3,
                          fontWeight: AppWeight.medium,
                          color: colors.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        text,
                        style: TextStyle(
                          fontSize: AppFontSize.labelLg,
                          height: 1.6,
                          color: colors.secondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '数据与隐私',
                  style: AppText.sheetTitle.copyWith(color: colors.text),
                ),
                const SizedBox(height: 6),
                Text(
                  '核心数据只保存在这台设备上。',
                  style: TextStyle(
                    fontSize: AppFontSize.caption,
                    height: 1.6,
                    color: colors.tertiary,
                  ),
                ),
                const SizedBox(height: 18),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        item(
                          Icons.folder_outlined,
                          '存放位置',
                          '应用私有目录，系统「文件」管理器看不到，也不随系统云备份上传。',
                        ),
                        item(
                          Icons.warning_amber_outlined,
                          '卸载风险',
                          '卸载 App 会一并删除，换机前请先在「备份与恢复」里导出 zip。',
                        ),
                        item(
                          Icons.schedule_outlined,
                          '自动备份',
                          '本机每天 1 份；开启文件夹后每 24 小时 1 份，各保留最近 3 份。',
                        ),
                        item(
                          Icons.lock_outline_rounded,
                          '锁定笔记',
                          '密文只在本机可解密；导出 zip 默认不含锁定笔记与「回收站」。',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Material(
                  color: colors.surface2,
                  borderRadius: BorderRadius.circular(AppRadius.button),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => Navigator.of(sheetContext).pop(),
                    child: SizedBox(
                      height: AppSize.button,
                      child: Center(
                        child: Text(
                          '知道了',
                          style: TextStyle(
                            fontSize: AppFontSize.body,
                            fontWeight: AppWeight.medium,
                            color: colors.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, AppColors colors) {
    return SizedBox(
      height: AppSize.navBar,
      child: Row(
        children: <Widget>[
          const AppBackButton(),
          Text(
            '设置',
            style: AppText.sheetTitle.copyWith(color: colors.text),
          ),
        ],
      ),
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
      final String? pin = await promptPinSheet(context, title: '设置应用锁 PIN');
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
        deviceSecure ? '已开启应用锁：使用系统锁屏验证' : '已开启应用锁：使用 PIN 解锁',
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
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
                  child: Text(
                    title,
                    style: AppText.sheetTitle.copyWith(color: colors.text),
                  ),
                ),
                for (var i = 0; i < options.length; i++) ...<Widget>[
                  if (i > 0)
                    Divider(
                      height: 0.5,
                      thickness: 0.5,
                      indent: AppSpace.lg,
                      color: colors.divider,
                    ),
                  AppPressable(
                    onTap: () => Navigator.of(sheetContext).pop(options[i]),
                    pressedScale: 1,
                    child: Container(
                      height: AppSize.actionRow,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      alignment: Alignment.centerLeft,
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              labelOf(options[i]),
                              style: TextStyle(
                                  fontSize: AppFontSize.summary,
                                  color: colors.text),
                            ),
                          ),
                          if (options[i] == current)
                            Icon(Icons.check_rounded,
                                size: AppIcon.chevron, color: colors.accent),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  bool _restoring = false;

  /// 「备份与恢复」入口：所有备份能力都收在这个弹层里。
  ///
  /// 主界面只保留一行，是为了避免「备份」和「自动备份到文件夹」并排出现
  /// 造成的困惑 —— 自动备份是一个开关，不是与「备份」平行的功能。
  Future<void> _openBackupMenu() async {
    if (_backingUp || _exporting || _restoring) {
      return;
    }
    final NoteSettings settings = repository.settings;
    final bool autoEnabled = settings.externalBackupUri != null;
    final BackupAction? action = await showBackupMenu(
      context,
      autoEnabled: autoEnabled,
      autoBusy: repository.externalBackupRunning,
      autoStatusLabel: _autoBackupStatusText(),
      folderLabel: backupFolderLabel(settings.externalBackupUri),
      lastBackupLabel: _backupStatusText(),
    );
    if (action == null || !mounted) {
      return;
    }
    switch (action) {
      case BackupAction.enableAuto:
      case BackupAction.changeFolder:
        await _chooseExternalBackupFolder();
      case BackupAction.disableAuto:
        await repository.updateSettings(
          repository.settings.copyWith(clearExternalBackup: true),
        );
        if (mounted) {
          _showSnack('已关闭自动备份');
        }
      case BackupAction.backupNow:
        await _backupNow();
      case BackupAction.exportZip:
        await _exportAll();
      case BackupAction.restore:
        await _restoreBackup();
    }
  }

  /// 弹层标题下的一行状态：备份成功时间 / 失败提示 / 尚无备份。
  String _backupStatusText() {
    if (repository.lastBackupError != null) {
      return '上次自动备份失败，可点「立即备份」重试';
    }
    if (_lastBackup == null) {
      return '还没有备份。建议先「立即备份」一次。';
    }
    return '最近备份：${formatListTime(_lastBackup!)}';
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
        builder: (BuildContext context) => TrashPage(repository: repository),
      ),
    );
  }

  Future<void> _openTags() async {
    hideSnack(context);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => TagsPage(repository: repository),
      ),
    );
  }

  Future<void> _pickSortOrder(
    BuildContext context,
    NoteSettings settings,
  ) async {
    final picked = await _pickOption<SortOrder>(
      context: context,
      title: '排序方式',
      options: SortOrder.values,
      current: settings.sortOrder,
      labelOf: (SortOrder order) => order.label,
    );
    if (picked == null) {
      return;
    }
    await repository.updateSettings(settings.copyWith(sortOrder: picked));
  }

  /// 从备份恢复：先选来源（应用内备份 / 系统文件）→ 确认覆盖 → 执行。
  ///
  /// 应用内备份在私有目录，系统文件管理器看不到，必须在这里列出来 ——
  /// 否则「立即备份」「每日自动备份」永远没有恢复入口。
  Future<void> _restoreBackup() async {
    final String? source = await _pickRestoreSource();
    if (source == null || !mounted) {
      return;
    }

    String? path = source == pickBackupFileSentinel ? null : source;
    if (source == pickBackupFileSentinel) {
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

  /// 选择恢复来源：应用内备份列表 + 「从 zip 文件选择…」。
  Future<String?> _pickRestoreSource() async {
    final List<BackupEntry> backups = await repository.listBackups();
    if (!mounted) {
      return null;
    }
    return showRestoreSourceMenu(context, backups: backups);
  }

  Future<void> _showRestoreResult(int restored, int skipped) {
    return showXiaojiSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        final sheetColors = AppColors.of(sheetContext);
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  restored == 0 ? '没有可恢复的内容' : '恢复完成',
                  style: AppText.sheetTitle.copyWith(color: sheetColors.text),
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
                    fontSize: AppFontSize.hint,
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
                    child: Icon(icon, size: AppIcon.action, color: colors.text),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          label,
                          style: TextStyle(
                              fontSize: AppFontSize.summary,
                              color: colors.text),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: AppFontSize.meta,
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
                  icon: Icons.lock_outline_rounded,
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
    showSnack(context, message: text);
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
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
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
                fontSize: AppFontSize.labelLg,
                height: 1.7,
                color: colors.secondary,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: AppSize.button,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(
                  backgroundColor: colors.surface2,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.button),
                  ),
                ),
                child: Text(
                  '好',
                  style: TextStyle(
                    fontSize: AppFontSize.body,
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

/// 人类可读的字节数：B / KB / MB / GB。
String _formatBytes(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  const List<String> units = <String>['KB', 'MB', 'GB', 'TB'];
  double value = bytes / 1024;
  int index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  final String text =
      value >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$text ${units[index]}';
}
