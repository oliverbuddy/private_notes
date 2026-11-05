import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 标签配色：同一个标签在所有位置（列表卡片、详情底部、正文胶囊、
/// 标签弹层）都取同一个颜色。
///
/// 参考滴答清单的做法：标签颜色跟着标签本身走，而不是跟着页面走 ——
/// 这样扫一眼列表就能靠颜色把标签分出来；同一标签换到详情页也还是
/// 那个颜色，不会出现「列表是蓝的、详情是灰的」这种割裂感。
///
/// 颜色由标签名**确定性**映射到一组低饱和色板（不依赖随机数/哈希对象），
/// 进程重启、设备切换后都保持一致。
class TagTone {
  const TagTone({
    required this.background,
    required this.foreground,
    required this.border,
  });

  /// 胶囊底色。
  final Color background;

  /// 文字颜色（同色系加深/提亮，保证可读）。
  final Color foreground;

  /// 0.5px 描边。
  final Color border;
}

abstract final class TagPalette {
  /// 8 个色相：蓝、绿、琥珀、紫、青、玫红、靛、湖蓝。
  ///
  /// 低饱和、偏中性的色相，浅色/深色主题下都不会抢正文的视觉重心。
  static const List<Color> _hues = <Color>[
    Color(0xFF3B82F6),
    Color(0xFF16A34A),
    Color(0xFFF59E0B),
    Color(0xFF8B5CF6),
    Color(0xFF0D9488),
    Color(0xFFE11D48),
    Color(0xFF6366F1),
    Color(0xFF0891B2),
  ];

  /// 为标签取一个稳定配色。
  static TagTone toneFor(String tag, AppColors colors) {
    final Color hue = _hues[_stableHash(tag) % _hues.length];
    final bool dark = colors.page.computeLuminance() < 0.3;
    if (dark) {
      return TagTone(
        // 深色主题：底色压到页面暗底上，文字提亮一档。
        background: Color.alphaBlend(
          hue.withValues(alpha: 0.26),
          colors.pageAlt,
        ),
        foreground: Color.lerp(hue, Colors.white, 0.58)!,
        border: hue.withValues(alpha: 0.42),
      );
    }
    return TagTone(
      // 浅色主题：12% 色相底，文字压深一档保证对比度。
      background: Color.alphaBlend(
        hue.withValues(alpha: 0.12),
        colors.page,
      ),
      foreground: Color.lerp(hue, Colors.black, 0.22)!,
      border: hue.withValues(alpha: 0.22),
    );
  }

  /// 内容稳定的哈希（不使用 String.hashCode：跨进程不保证一致）。
  static int _stableHash(String value) {
    var hash = 0;
    for (final int unit in value.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return hash;
  }
}
