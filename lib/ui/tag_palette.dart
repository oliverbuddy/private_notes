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
  /// 8 个色相直接取自 iOS 系统色（蓝/绿/橙/紫/粉/青/靛/棕），
  /// 再压一档饱和度，保证白卡上能区分、又不抢正文。
  static const List<Color> _hues = <Color>[
    Color(0xFF0A84FF), // systemBlue
    Color(0xFF34C759), // systemGreen
    Color(0xFFFF9F0A), // systemOrange
    Color(0xFFBF5AF2), // systemPurple
    Color(0xFFFF375F), // systemPink
    Color(0xFF30B0C7), // systemTeal
    Color(0xFF5E5CE6), // systemIndigo
    Color(0xFFA2845E), // systemBrown
  ];

  /// 为标签取一个稳定配色。
  static TagTone toneFor(String tag, AppColors colors) {
    final Color hue = _hues[_stableHash(tag) % _hues.length];
    final bool dark = colors.page.computeLuminance() < 0.3;
    if (dark) {
      return TagTone(
        // 深色主题：半透明色相叠在卡片底上，文字提亮一档。
        background: Color.alphaBlend(
          hue.withValues(alpha: 0.30),
          colors.page,
        ),
        foreground: Color.lerp(hue, Colors.white, 0.62)!,
        border: hue.withValues(alpha: 0.45),
      );
    }
    return TagTone(
      // 浅色主题：16% 色相底 + 加深文字/描边，iOS 彩色标签的常见做法。
      background: Color.alphaBlend(
        hue.withValues(alpha: 0.16),
        colors.page,
      ),
      foreground: Color.lerp(hue, Colors.black, 0.30)!,
      border: hue.withValues(alpha: 0.28),
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
