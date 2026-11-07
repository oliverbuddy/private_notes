import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../theme/app_theme.dart';
import '../ui/app_icon_button.dart';
import '../ui/app_list.dart';
import '../ui/content_frame.dart';
import '../ui/show_sheet.dart';
import '../ui/snack.dart';
import '../util/app_info.dart';
import '../util/external_link.dart';

/// 关于页。
///
/// 设置页只留一个「关于」入口：版本、许可、联系方式都属于低频信息，
/// 平铺在设置页里会把「外观 / 安全 / 数据」三组的节奏打断。
/// 这里单独一页，顶部是应用身份，下面是可操作的元信息。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  static const String _repoUrl = 'https://github.com/oliverbuddy/private_notes';
  static const String _contactEmail = 'qiwei0727@gmail.com';

  /// 从已安装的 APK 读取版本；拿不到时页面其余内容照常显示。
  AppInfo? _appInfo;

  @override
  void initState() {
    super.initState();
    _loadAppInfo();
  }

  Future<void> _loadAppInfo() async {
    final AppInfo? info = await loadAppInfo();
    if (mounted) {
      setState(() => _appInfo = info);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);

    return Scaffold(
      backgroundColor: colors.pageAlt,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _buildHeader(context, colors),
            Expanded(
              // 平板/宽屏上限宽居中，与设置页保持同一套版心。
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
                    const SizedBox(height: 24),
                    _buildIdentity(colors),
                    const SizedBox(height: 32),
                    AppListSection(
                      children: <Widget>[
                        AppListRow(
                          label: '开源许可',
                          value: 'PolyForm 非商业',
                          chevron: true,
                          onTap: _showLicenseSheet,
                        ),
                        AppListRow(
                          label: '联系作者',
                          value: _contactEmail,
                          chevron: true,
                          onTap: _copyContactEmail,
                        ),
                        AppListRow(
                          label: '项目主页',
                          value: 'GitHub',
                          chevron: true,
                          onTap: () => openExternalLink(_repoUrl),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Center(
                      child: Text(
                        '${_appInfo?.packageName ?? 'com.xiaoji.xiaoji'}'
                        ' · 数据仅保存在本机',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: AppFontSize.caption,
                            color: colors.tertiary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 应用身份区：图标、名称、一句话定位、版本号。
  ///
  /// 版本号做成小胶囊而不是普通行，是为了让「我现在用的是哪个版本」
  /// 这一眼能被看到（反馈问题时用户第一句话往往就是这个）。
  Widget _buildIdentity(AppColors colors) {
    return Column(
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Image.asset(
            'assets/app_icon.png',
            width: 76,
            height: 76,
            filterQuality: FilterQuality.high,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          '小记',
          style: TextStyle(
            fontSize: AppFontSize.title,
            height: 1.3,
            fontWeight: AppWeight.medium,
            letterSpacing: 0.3,
            color: colors.text,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '你的笔记，只属于你。',
          style: TextStyle(
            fontSize: AppFontSize.label,
            height: 1.4,
            color: colors.tertiary,
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            // surface2 在浅色下几乎与页面同色，补一圈描边（与搜索框、
            // 筛选 chip 同一套「浅底 + 细边」语言），深色下同样成立。
            color: colors.surface2,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: colors.chipBorder, width: 0.5),
          ),
          child: Text(
            _appInfo == null ? '版本 —' : '版本 ${_appInfo!.displayVersion}',
            style: TextStyle(
                fontSize: AppFontSize.caption, color: colors.secondary),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context, AppColors colors) {
    return SizedBox(
      height: AppSize.navBar,
      child: Row(
        children: <Widget>[
          const AppBackButton(),
          Text(
            '关于',
            style: AppText.sheetTitle.copyWith(color: colors.text),
          ),
        ],
      ),
    );
  }

  Future<void> _copyContactEmail() async {
    await Clipboard.setData(const ClipboardData(text: _contactEmail));
    if (mounted) {
      showSnack(
        context,
        message: '邮箱已复制',
        duration: const Duration(seconds: 3),
      );
    }
  }

  Future<void> _showLicenseSheet() {
    return showXiaojiSheet<void>(
      context: context,
      builder: (BuildContext sheetContext) {
        final AppColors colors = AppColors.of(sheetContext);
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '开源许可',
                  style: AppText.sheetTitle.copyWith(color: colors.text),
                ),
                const SizedBox(height: 10),
                Text(
                  'PolyForm Noncommercial 1.0.0\n\n'
                  '个人与非商业用途可以自由使用、修改和分发；'
                  '商业用途需要获得作者的书面授权。',
                  style: TextStyle(
                    fontSize: AppFontSize.label,
                    height: 1.7,
                    color: colors.secondary,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '授权咨询：$_contactEmail',
                  style: TextStyle(
                      fontSize: AppFontSize.meta, color: colors.tertiary),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
