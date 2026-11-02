import 'package:flutter/material.dart';

/// 全站设计 token。
///
/// 产品规范把每个颜色都钉死了，业务代码里出现字面量颜色就一定会走形，
/// 所以统一收拢成 [ThemeExtension]，好处是浅/深色切换时框架会自己 lerp，
/// 而且 `Theme.of(context)` 一改，全站自动重建。
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.page,
    required this.pageAlt,
    required this.text,
    required this.secondary,
    required this.tertiary,
    required this.divider,
    required this.dividerStrong,
    required this.separator,
    required this.separatorCompact,
    required this.accent,
    required this.accentBg,
    required this.chipBorder,
    required this.chipBorderSelected,
    required this.syntaxMarker,
    required this.searchHit,
    required this.surface2,
    required this.fabBackground,
    required this.fabForeground,
    required this.danger,
  });

  /// 页面底色。
  final Color page;

  /// 次级页面底色（卡片/分组）。
  final Color pageAlt;

  /// 正文颜色。
  final Color text;

  /// 次要文字。
  final Color secondary;

  /// 三级文字（时间戳、占位）。
  final Color tertiary;

  /// 0.5px 通用分隔线。
  final Color divider;

  /// 更明显的分隔线（块之间的描边）。
  final Color dividerStrong;

  /// 列表分隔线（舒适密度）。
  final Color separator;

  /// 列表分隔线（紧凑密度，更淡）。
  final Color separatorCompact;

  /// 主色。
  final Color accent;

  /// 主色浅底。
  final Color accentBg;

  /// 未选中 chip 描边。
  final Color chipBorder;

  /// 选中 chip 描边（规范只给了浅色值 #B9D3FF，深色取同色系的暗调）。
  final Color chipBorderSelected;

  /// markdown 语法符号的「淡显色」。
  final Color syntaxMarker;

  /// 搜索命中底色。
  final Color searchHit;

  /// 比 pageAlt 再深一档的表面色（输入框、文件卡片）。
  final Color surface2;

  /// 悬浮按钮底色。
  final Color fabBackground;

  /// 破坏性操作（删除）。国内规范：确认删除必须是红色，不能复用强调色。
  final Color danger;

  /// 悬浮按钮图标色。
  final Color fabForeground;

  static const AppColors light = AppColors(
    page: Color(0xFFFFFFFF),
    pageAlt: Color(0xFFF7F5F0),
    text: Color(0xFF2C2C2A),
    secondary: Color(0xFF8F8C84),
    tertiary: Color(0xFFA9A69D),
    divider: Color(0x0F000000), // rgba(0,0,0,0.06)
    dividerStrong: Color(0xFFEFEDE6),
    separator: Color(0xFFF2F0E9),
    separatorCompact: Color(0xFFF7F5EE),
    accent: Color(0xFF0A6CFF),
    accentBg: Color(0xFFEDF3FF),
    chipBorder: Color(0xFFE0DED6),
    chipBorderSelected: Color(0xFFB9D3FF),
    syntaxMarker: Color(0xFFD3D1C7),
    searchHit: Color(0xFFD9E7FF),
    surface2: Color(0xFFF5F3EC),
    fabBackground: Color(0xFF2C2C2A),
    fabForeground: Color(0xFFFFFFFF),
    danger: Color(0xFFDD4B4B),
  );

  static const AppColors dark = AppColors(
    page: Color(0xFF161514),
    // 深色的卡片/分组表面：必须比 page 亮出可感知的一档。
    // 旧值 #1A1917 与 page 只差一线，卡片浮在页面上完全看不出轮廓
    // （用户实测反馈）。层级设计：page #161514 < pageAlt #201F1D
    // < surface2 #232220，三档表面各自分明。
    pageAlt: Color(0xFF201F1D),
    text: Color(0xFFE9E7E2),
    secondary: Color(0xFF8F8C84),
    tertiary: Color(0xFF7C7972),
    divider: Color(0x12FFFFFF), // rgba(255,255,255,0.07)
    dividerStrong: Color(0xFF302F2C),
    // 深色下分隔线必须比底色亮出可感知的一档：#232220 在 #161514 上
    // 肉眼几乎不可见（用户报过「暗黑模式下有些效果看不到」）。
    separator: Color(0xFF2E2D2A),
    separatorCompact: Color(0xFF262523),
    accent: Color(0xFF7DB2FF),
    accentBg: Color(0xFF1C2637),
    chipBorder: Color(0xFF3A3835),
    chipBorderSelected: Color(0xFF35507A),
    syntaxMarker: Color(0xFF4F4D47),
    // 搜索命中底色同理：#1B2431 与底色几乎同亮度，高亮等于没高。
    searchHit: Color(0xFF24334F),
    surface2: Color(0xFF232220),
    fabBackground: Color(0xFFE9E7E2),
    fabForeground: Color(0xFF161514),
    danger: Color(0xFFFF7076),
  );

  /// 取当前主题的 token。拿不到扩展时退回浅色，保证 UI 永远不会崩。
  static AppColors of(BuildContext context) {
    return Theme.of(context).extension<AppColors>() ?? AppColors.light;
  }

  @override
  AppColors copyWith({
    Color? page,
    Color? pageAlt,
    Color? text,
    Color? secondary,
    Color? tertiary,
    Color? divider,
    Color? dividerStrong,
    Color? separator,
    Color? separatorCompact,
    Color? accent,
    Color? accentBg,
    Color? chipBorder,
    Color? chipBorderSelected,
    Color? syntaxMarker,
    Color? searchHit,
    Color? surface2,
    Color? fabBackground,
    Color? fabForeground,
    Color? danger,
  }) {
    return AppColors(
      page: page ?? this.page,
      pageAlt: pageAlt ?? this.pageAlt,
      text: text ?? this.text,
      secondary: secondary ?? this.secondary,
      tertiary: tertiary ?? this.tertiary,
      divider: divider ?? this.divider,
      dividerStrong: dividerStrong ?? this.dividerStrong,
      separator: separator ?? this.separator,
      separatorCompact: separatorCompact ?? this.separatorCompact,
      accent: accent ?? this.accent,
      accentBg: accentBg ?? this.accentBg,
      chipBorder: chipBorder ?? this.chipBorder,
      chipBorderSelected: chipBorderSelected ?? this.chipBorderSelected,
      syntaxMarker: syntaxMarker ?? this.syntaxMarker,
      searchHit: searchHit ?? this.searchHit,
      surface2: surface2 ?? this.surface2,
      fabBackground: fabBackground ?? this.fabBackground,
      fabForeground: fabForeground ?? this.fabForeground,
      danger: danger ?? this.danger,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) {
      return this;
    }
    return AppColors(
      page: Color.lerp(page, other.page, t) ?? page,
      pageAlt: Color.lerp(pageAlt, other.pageAlt, t) ?? pageAlt,
      text: Color.lerp(text, other.text, t) ?? text,
      secondary: Color.lerp(secondary, other.secondary, t) ?? secondary,
      tertiary: Color.lerp(tertiary, other.tertiary, t) ?? tertiary,
      divider: Color.lerp(divider, other.divider, t) ?? divider,
      dividerStrong:
          Color.lerp(dividerStrong, other.dividerStrong, t) ?? dividerStrong,
      separator: Color.lerp(separator, other.separator, t) ?? separator,
      separatorCompact:
          Color.lerp(separatorCompact, other.separatorCompact, t) ??
              separatorCompact,
      accent: Color.lerp(accent, other.accent, t) ?? accent,
      accentBg: Color.lerp(accentBg, other.accentBg, t) ?? accentBg,
      chipBorder: Color.lerp(chipBorder, other.chipBorder, t) ?? chipBorder,
      chipBorderSelected:
          Color.lerp(chipBorderSelected, other.chipBorderSelected, t) ??
              chipBorderSelected,
      syntaxMarker:
          Color.lerp(syntaxMarker, other.syntaxMarker, t) ?? syntaxMarker,
      searchHit: Color.lerp(searchHit, other.searchHit, t) ?? searchHit,
      surface2: Color.lerp(surface2, other.surface2, t) ?? surface2,
      fabBackground:
          Color.lerp(fabBackground, other.fabBackground, t) ?? fabBackground,
      fabForeground:
          Color.lerp(fabForeground, other.fabForeground, t) ?? fabForeground,
      danger: Color.lerp(danger, other.danger, t) ?? danger,
    );
  }
}

/// 圆角 token。只有三档，避免「每个组件自己拍一个数」。
abstract final class AppRadius {
  static const double block = 8;
  static const double card = 10;
  static const double chip = 11;
}

/// 引用块（引文块）视觉规格。
///
/// 详情编辑器与列表摘要共用这一组数值。之前两边各写一套（底色偏蓝、
/// 内边距 18 / 10、竖条色也不同），同一条笔记点进去会像换了一篇东西。
/// 语雀的引用块是**中性浅灰底 + 左侧灰竖条 + 小圆角**（不是蓝色高亮），
/// 这里照此定稿：改这里 = 两处一起生效。
abstract final class AppQuote {
  /// 左侧竖条宽度。
  static const double barWidth = 3;

  /// 块内边距（在竖条之后算）。横向/纵向单独留常量，
  /// 供 super_editor 的 `CascadingPadding` 在 const 上下文里直接用
  /// （Dart 不允许对 const EdgeInsets 做属性访问求值）。
  static const double padHorizontal = 12;

  /// 纵向 8：官方 BlockquoteComponent 内部固定 16/16，单行引用块会到 56dp，
  /// 明显比语雀/GitHub 的引文块「胖」一圈。8 + 行盒 24 = 40dp，与竞品同高。
  static const double padVertical = 8;
  static const EdgeInsets padding = EdgeInsets.symmetric(
    horizontal: padHorizontal,
    vertical: padVertical,
  );

  /// 圆角。
  static const double radius = 6;

  /// 引文字阶：比正文小一档，形成「引文」的层级差。
  static const double fontSize = 14.5;
  static const double height = 1.65;
  static const double letterSpacing = 0.25;
}

/// 三档字重。
///
/// 中文只有 Regular / Medium 两个真实字面，w500 和 w600 在 Android 上会落到
/// 不同字面（Medium 与 Bold 之间），这就是「标题看着不够精神」的原因 ——
/// 之前全局只有 400/500，标题和正文的中文粗细差几乎看不出来。
/// 所以标题类一律走 [semibold]，正文走 [regular]，弱强调才用 [medium]。
abstract final class AppWeight {
  static const FontWeight regular = FontWeight.w400;
  static const FontWeight medium = FontWeight.w500;
  static const FontWeight semibold = FontWeight.w600;
}

/// 字阶。
///
/// 中文没有西文那样的 x-height 视觉补偿，字号偏小、行高偏紧时整页会显得
/// 「挤」和「灰」。这里按国内主流资讯/工具类 App 的取值定档：
/// 页面标题 22 / 区块标题 17 / 正文 16 / 辅助 13 / 最小 12。
/// 中文标题额外加 0.2–0.3 的字距，横排才不觉得粘连。
abstract final class AppText {
  /// 页面标题（主页「小记」、设置页标题）。
  static const TextStyle pageTitle = TextStyle(
    fontSize: 22,
    height: 1.25,
    fontWeight: AppWeight.semibold,
    letterSpacing: 0.3,
  );

  /// 弹层/对话框标题。
  static const TextStyle sheetTitle = TextStyle(
    fontSize: 17,
    height: 1.3,
    fontWeight: AppWeight.semibold,
    letterSpacing: 0.2,
  );

  /// 正文。列表摘要与阅读态共用。
  static const TextStyle body = TextStyle(
    fontSize: 16,
    height: 1.68,
  );

  /// 列表元信息（时间、字数）。
  static const TextStyle meta = TextStyle(
    fontSize: 12.5,
    height: 1.2,
    letterSpacing: 0.1,
  );

  /// 分组小标题。
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    height: 1.2,
    fontWeight: AppWeight.medium,
    letterSpacing: 0.3,
  );
}

/// 间距只用 4 的倍数，避免出现 5、7、11 这种「看起来差一点」的值。
abstract final class AppSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 28;

  /// 页面左右边距。列表、编辑区、设置页统一用这一个值。
  static const double page = 20;
}

abstract final class AppTheme {
  static ThemeData light() => _build(AppColors.light, Brightness.light);

  static ThemeData dark() => _build(AppColors.dark, Brightness.dark);

  static ThemeData _build(AppColors c, Brightness brightness) {
    final base = ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: c.page,
      colorScheme: ColorScheme.fromSeed(
        seedColor: c.accent,
        brightness: brightness,
      ).copyWith(
        primary: c.accent,
        secondary: c.accent,
        surface: c.page,
        onSurface: c.text,
      ),
      // 规范明确禁止阴影/渐变/模糊，所以把所有水波纹也关掉，只留 InkWell 的按压色。
      splashFactory: NoSplash.splashFactory,
      highlightColor: c.divider,
      hoverColor: Colors.transparent,
      dividerColor: c.divider,
      canvasColor: c.page,
      fontFamily: null,
      visualDensity: VisualDensity.standard,
    );

    return base.copyWith(
      extensions: <ThemeExtension<dynamic>>[c],
      textTheme: base.textTheme.apply(
        bodyColor: c.text,
        displayColor: c.text,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: c.accent,
        selectionColor: c.accentBg,
        selectionHandleColor: c.accent,
      ),
      iconTheme: IconThemeData(color: c.secondary),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.text,
        contentTextStyle: TextStyle(
          color: c.page,
          fontSize: 13,
          fontWeight: AppWeight.regular,
        ),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.page,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
        ),
      ),
      // 弹窗统一成纸白 + 无阴影：Material 3 默认用带色调的灰底，
      // 和「纸」的基调完全冲突，且阴影在规范里是禁用的。
      dialogTheme: DialogThemeData(
        backgroundColor: c.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: c.dividerStrong, width: 0.5),
        ),
        titleTextStyle: TextStyle(
          color: c.text,
          fontSize: 16,
          fontWeight: AppWeight.medium,
        ),
        contentTextStyle: TextStyle(
          color: c.secondary,
          fontSize: 14,
          height: 1.6,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.page,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(color: c.dividerStrong, width: 0.5),
        ),
        textStyle: TextStyle(
          color: c.text,
          fontSize: 14,
          fontWeight: AppWeight.regular,
        ),
      ),
    );
  }
}
