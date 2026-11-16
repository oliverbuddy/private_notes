import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 全站统一的空态：柔和圆角徽章 + 一句标题 + 可选说明。
///
/// 此前各页面空态是三套规格（主页插画 20 号标题、标签页 14/12 纯文字、
/// 回收站 48 号裸图标 + 16 号文字），放在一起风格不统一。这里收口成
/// 一个规格：64 徽章 + 16 号标题 + 14 号说明，尺寸克制、和卡片圆角语言
/// 一致，也不会出现「空白页中间一个很大的图标」。
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.hint,
  });

  final IconData icon;
  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                // 用「卡片底 + 细描边」而不是 surface2：标签页/回收站/主页
                // 搜索态的页底本身就是 surface2 同色，纯色块会完全看不见。
                color: colors.page,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: colors.chipBorder, width: 0.8),
              ),
              child: Icon(icon, size: 26, color: colors.tertiary),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppFontSize.hint,
                height: 1.3,
                fontWeight: AppWeight.medium,
                letterSpacing: 0.1,
                color: colors.text,
              ),
            ),
            if (hint != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppFontSize.label,
                  height: 1.4,
                  color: colors.secondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
