import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/note_repository.dart';
import '../models/note_settings.dart';
import '../theme/app_theme.dart';
import '../ui/show_sheet.dart';
import '../util/date_format.dart';

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
                          _ExportRow(
                            exporting: _exporting,
                            onTap: _exporting ? null : _exportAll,
                          ),
                        ],
                      ),
                      Padding(
                        // 说明文字和卡片左边缘对齐，比再缩进 6px 更整齐
                        padding: EdgeInsets.zero,
                        child: Text(
                          '笔记是纯文本文件，存在「文件」App 的 Xiaoji 目录下。'
                          '卸载 App 会一并删除，重要内容记得定期导出。',
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.75,
                            color: colors.tertiary,
                          ),
                        ),
                      ),
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

  /// 导出全部：打包 zip → 系统保存对话框。系统对话框不可用（罕见，
  /// ROM 裁剪）时回退到私有目录导出，至少数据出得去。
  Future<void> _exportAll() async {
    setState(() => _exporting = true);
    try {
      final data = await repository.store.buildExportZip();
      final stamp = formatExportStamp(DateTime.now());
      final saved = await FilePicker.platform.saveFile(
        fileName: 'xiaoji-export-$stamp.zip',
        type: FileType.custom,
        allowedExtensions: <String>['zip'],
        bytes: data,
      );
      if (!mounted) {
        return;
      }
      if (saved == null) {
        return; // 用户在系统对话框点了取消，静默返回
      }
      await showXiaojiSheet<void>(
        context: context,
        builder: (BuildContext sheetContext) {
          return _ExportResultSheet(message: '导出文件已保存到：\n$saved');
        },
      );
    } catch (_) {
      try {
        final path = await repository.exportAll();
        if (!mounted) {
          return;
        }
        await showXiaojiSheet<void>(
          context: context,
          builder: (BuildContext sheetContext) {
            return _ExportResultSheet(
              message: '系统保存对话框不可用，已导出到应用目录（需从应用信息里取文件）：\n$path',
            );
          },
        );
      } catch (error) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
                content: Text('导出失败：$error'),
                duration: const Duration(seconds: 3)),
          );
      }
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }
}

/// 「导出全部」行：导出中行内转圈并禁点，平时和普通设置行同款。
class _ExportRow extends StatelessWidget {
  const _ExportRow({required this.exporting, required this.onTap});

  final bool exporting;
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
                '导出全部',
                style: TextStyle(
                  fontSize: 16,
                  color: exporting ? colors.tertiary : colors.text,
                ),
              ),
            ),
            if (exporting)
              const SizedBox(
                width: 15,
                height: 15,
                child: CircularProgressIndicator(strokeWidth: 1.8),
              )
            else
              Icon(Icons.ios_share, size: 17, color: colors.secondary),
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }
}

/// 导出结果弹层：标题 + 多行说明 + 单个「好」按钮。
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
              '导出完成',
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
  final VoidCallback onTap;

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
