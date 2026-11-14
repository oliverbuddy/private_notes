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
    required this.onDanger,
    required this.inverseAccent,
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

  /// 危险色之上的文字：浅色主题用白字，深色主题的红更亮、改用黑字，
  /// 否则白字在 #FF6B5B 上只有 2.8:1。
  final Color onDanger;

  /// 反色容器（SnackBar）上的强调色。
  ///
  /// SnackBar 底色始终是「文字色」（浅色主题深底、深色主题浅底），
  /// 普通 accent 在上面只有约 2:1，这里给一组专门的反色强调。
  final Color inverseAccent;

  /// 悬浮按钮图标色。
  final Color fabForeground;

  /// HarmonyOS 色板（浅色）。
  ///
  /// page 是页面/卡片底色，pageAlt 是分组页的灰底：
  /// 页面 #FFFFFF、分组底 #F1F3F5、卡片 #FFFFFF；
  /// 深色反过来：分组底 #000000、卡片 #1A1A1A。
  /// 这样设置类页面是「灰底白卡」，编辑页是纯白/近黑，符合鸿蒙的层次。
  static const AppColors light = AppColors(
    page: Color(0xFFFFFFFF),
    pageAlt: Color(0xFFF1F3F5),
    // 鸿蒙一级文字 #182431（不是纯黑，降低对比锐度）。
    text: Color(0xFF182431),
    secondary: Color(0xFF66707D),
    tertiary: Color(0xFF99A1AD),
    divider: Color(0x33182431),
    dividerStrong: Color(0xFFE5E6EB),
    separator: Color(0xFFE8EAED),
    separatorCompact: Color(0xFFF1F3F5),
    // 鸿蒙品牌蓝：链接、选中、主按钮共用。
    accent: Color(0xFF0A59F7),
    accentBg: Color(0xFFE8F0FF),
    chipBorder: Color(0xFFDCE0E5),
    chipBorderSelected: Color(0xFF99BCFF),
    syntaxMarker: Color(0xFFC5CAD3),
    searchHit: Color(0xFFCCE0FF),
    surface2: Color(0xFFF1F3F5),
    fabBackground: Color(0xFF0A59F7),
    fabForeground: Color(0xFFFFFFFF),
    // 比品牌红略深一档：保证白字 4.8:1、红字在白底 4.8:1。
    danger: Color(0xFFD6341F),
    onDanger: Color(0xFFFFFFFF),
    inverseAccent: Color(0xFF8AB4FF),
  );

  static const AppColors dark = AppColors(
    page: Color(0xFF1A1A1A),
    pageAlt: Color(0xFF000000),
    text: Color(0xFFE5E5E5),
    secondary: Color(0xFF99A1AD),
    // 比 page/surface2 都亮：12 号灰色说明文字在 #26282B 上仍有 5:1。
    tertiary: Color(0xFF8E97A4),
    divider: Color(0x33FFFFFF),
    dividerStrong: Color(0xFF2E3135),
    separator: Color(0xFF2E3135),
    separatorCompact: Color(0xFF242424),
    // 深色下提亮品牌蓝，保证 4.5:1 以上对比度。
    accent: Color(0xFF5291FF),
    // 14%：再高会让选中 chip 上的蓝字掉到 4.5:1 以下。
    accentBg: Color(0x245291FF),
    chipBorder: Color(0xFF3A3F45),
    chipBorderSelected: Color(0xFF5291FF),
    syntaxMarker: Color(0xFF6E7681),
    searchHit: Color(0x405291FF),
    surface2: Color(0xFF26282B),
    fabBackground: Color(0xFF5291FF),
    fabForeground: Color(0xFF000000),
    danger: Color(0xFFFF6B5B),
    onDanger: Color(0xFF000000),
    inverseAccent: Color(0xFF0A4FD6),
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
    Color? onDanger,
    Color? inverseAccent,
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
      onDanger: onDanger ?? this.onDanger,
      inverseAccent: inverseAccent ?? this.inverseAccent,
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
      onDanger: Color.lerp(onDanger, other.onDanger, t) ?? onDanger,
      inverseAccent:
          Color.lerp(inverseAccent, other.inverseAccent, t) ?? inverseAccent,
    );
  }
}

/// 圆角 token（HarmonyOS Design）。
///
/// 官方圆角参数：标签/角标 4、图片/图标 8、内容卡片 16、
/// 按钮与菜单 20、输入框 20、搜索框 18。业务代码只引这里的名字，
/// 以后调圆角只改这一处。
abstract final class AppRadius {
  static const double block = 8;

  /// 内容卡片、分组列表：16。
  static const double card = 16;

  /// 按钮、菜单、弹层操作：20。
  static const double button = 20;

  /// 标签胶囊：官方「标签」用小圆角 4。
  static const double chip = 4;

  /// 缩略图、文件图标这类小图：8。
  static const double thumb = 8;

  /// 底部弹层顶部两角：20。
  static const double sheet = 20;

  /// 输入框：20。
  static const double field = 20;

  /// 搜索框：18。
  static const double search = 18;

  /// 胶囊：版本号这类高度约 24dp 的圆角块。
  static const double pill = 999;
}

/// HarmonyOS 的连续圆角（与系统卡片一致）。
///
/// 卡片、按钮、浮层优先用它；`Container` 里改用 `ShapeDecoration` 承载。
abstract final class AppShape {
  static ShapeBorder continuous(double radius) {
    return RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(radius),
    );
  }
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
  static const double radius = 8;

  /// 引文字阶：比正文小一档，形成「引文」的层级差。
  static const double fontSize = 15.5;
  static const double height = 1.65;
  static const double letterSpacing = 0.25;
}

/// 字重档位（HarmonyOS 只用 Regular / Medium / Bold 三档）。
///
/// 中文在 Android 上没有 600 字面，w600 会落到 Bold 附近；
/// 标题用 [semibold] 保持「精神」，正文 [regular]，弱强调 [medium]。
abstract final class AppWeight {
  static const FontWeight regular = FontWeight.w400;
  static const FontWeight medium = FontWeight.w500;
  static const FontWeight semibold = FontWeight.w600;
}

/// 字阶（HarmonyOS Design 的字号阶梯）。
///
/// 大标题 30 Bold / 标题 24 Bold / 小标题 20 Medium / 正文 16 Regular /
/// 辅助 14 / 说明 12。行高按官方 24→32、16→24、14→20、12→18 换算。
/// 业务代码只用这里的语义样式，不再自己拍字号。
abstract final class AppText {
  /// 主页标题（HarmonyOS 标题 24 Bold）。
  static const TextStyle pageTitle = TextStyle(
    fontSize: AppFontSize.pageTitle,
    height: 1.25,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
  );

  /// 导航栏 / 弹层标题（HarmonyOS 小标题 20 Medium）。
  static const TextStyle sheetTitle = TextStyle(
    fontSize: AppFontSize.subtitle,
    height: 1.3,
    fontWeight: AppWeight.medium,
    letterSpacing: 0,
  );

  /// 正文。列表摘要与阅读态共用（HarmonyOS 正文 16 / 行高 24）。
  static const TextStyle body = TextStyle(
    fontSize: AppFontSize.body,
    height: 1.5,
    letterSpacing: 0,
  );

  /// 列表元信息（时间、字数），HarmonyOS 说明文字 12 / 行高 18。
  static const TextStyle meta = TextStyle(
    fontSize: AppFontSize.meta,
    height: 1.5,
    letterSpacing: 0,
  );

  /// 分组小标题与说明文字（12 / 行高 18）。
  static const TextStyle caption = TextStyle(
    fontSize: AppFontSize.caption,
    height: 1.5,
    fontWeight: AppWeight.regular,
    letterSpacing: 0,
  );
}

/// 字号刻度：映射 HarmonyOS 的 12 / 14 / 16 / 20 / 24 / 30 六档。
///
/// 保留旧名字是为了让 40 多个调用点零改动地升级到新字阶；
/// 新增代码请优先用 [AppText] 里的语义样式。
abstract final class AppFontSize {
  static const double tiny = 12;
  static const double micro = 12;
  static const double badge = 12;
  static const double badgeLg = 12;
  static const double caption = 12;
  static const double meta = 12;
  static const double label = 14;
  static const double labelLg = 14;
  static const double value = 14;
  static const double hint = 16;
  static const double summary = 16;
  static const double body = 16;
  static const double bodyLg = 16;
  static const double subtitle = 20;
  static const double heading = 20;
  static const double title = 20;
  static const double titleLg = 24;
  static const double pageTitle = 24;
}

/// 8vp 基线网格（HarmonyOS 的间距基准）。
abstract final class AppSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 32;

  /// 页面左右边距。鸿蒙内容页标准 16。
  static const double page = 16;
}

/// 组件高度刻度（HarmonyOS Design）。
///
/// 导航栏 48、单行列表 48、双行列表 64、标准按钮 40、菜单行 56。
/// 官方最小可点热区 40vp，这里的行高都不低于 48。
abstract final class AppSize {
  static const double navBar = 48;
  static const double row = 48;
  static const double rowLarge = 64;
  static const double button = 40;
  static const double actionRow = 56;
}

/// 图标尺寸刻度（HarmonyOS 系统图标 24vp，活动区 22vp；行内 16vp）。
abstract final class AppIcon {
  /// 返回箭头（系统导航图标 24）。
  static const double nav = 24;

  /// 行尾箭头、「⋯」这类弱操作图标。
  static const double chevron = 16;

  /// 顶部栏动作图标、弹层行动图标。
  static const double action = 24;

  /// 笔画密度高的图标（齿轮等）的光学尺寸。
  ///
  /// 齿轮的齿多、留白少，同样 24vp 会比返回箭头、放大镜重一圈；
  /// 鸿蒙图标规范也允许按视觉重量做 ±2vp 的光学补偿。
  static const double dense = 22;

  /// 次要动作 / 工具条图标（20）。
  static const double compact = 20;

  /// 输入框、提示卡这类行内图标。
  static const double inline = 16;

  /// 标签 chip 里的小图标（14）。
  static const double chip = 14;

  /// 置顶、锁定这类状态小标记。
  static const double badge = 12;

  /// 空态插图。
  static const double hero = 48;

  /// 悬浮按钮。圆形底是实色蓝，图标用实心笔，26 比 24 更压得住底色。
  static const double fab = 26;
}

/// 阴影梯度（HarmonyOS 的「立体感」= 极浅大模糊 + 少量下偏移）。
abstract final class AppShadow {
  /// 悬浮按钮：16 blur / 6 offset / 15% 黑。
  static const List<BoxShadow> floating = <BoxShadow>[
    BoxShadow(
      color: Color(0x26000000),
      blurRadius: 16,
      offset: Offset(0, 6),
    ),
  ];

  /// 底部弹层、气泡：24 blur / 上移 4。
  static const List<BoxShadow> sheet = <BoxShadow>[
    BoxShadow(
      color: Color(0x1F000000),
      blurRadius: 24,
      offset: Offset(0, -4),
    ),
  ];

  /// 卡片：官方 card shadow（blur 8 / y 2 / 8% 黑），
  /// 只用来和灰底分层，不制造重投影。
  static const List<BoxShadow> card = <BoxShadow>[
    BoxShadow(
      color: Color(0x14000000),
      blurRadius: 8,
      offset: Offset(0, 2),
    ),
  ];
}

/// 动效刻度。
///
/// 弹层用 300ms 的标准进出；按压反馈要更快，取 120ms。
abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration normal = Duration(milliseconds: 300);

  static const Curve decelerate = Cubic(0.0, 0, 0.2, 1);
  static const Curve accelerate = Cubic(0.4, 0, 1, 1);
}

/// 按压蒙层（卡片 / 列表行「被按住」时的整块底色）。
///
/// 叠加在内容上方，必须带透明度：浅色压 5% 黑、深色提 8% 白，
/// 两种主题下都是「轻微变暗/提亮」，文字与缩略图保持清晰。
abstract final class AppPress {
  static Color overlay(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0x14FFFFFF)
          : const Color(0x0D000000);
}

/// 响应式断点：手机 / 平板 / 桌面。
///
/// 目前先统一「内容最大宽度 + 居中」，后续做 Pad 双栏、PC 侧栏时
/// 只需要扩展这里，不用逐页改布局。
abstract final class AppBreakpoints {
  static const double compact = 600;
  static const double medium = 1024;

  static bool isCompact(double width) => width < compact;

  /// 单列内容的最大宽度：手机全宽，平板/桌面不把一行拉得过长。
  static double contentMaxWidth(double width) {
    if (isCompact(width)) {
      return width;
    }
    return width < medium ? 680 : 760;
  }
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
        // 深色主题的亮蓝上必须用黑字（白字只有 3.4:1）。
        onPrimary: c.fabForeground,
        secondary: c.accent,
        onSecondary: c.fabForeground,
        surface: c.page,
        onSurface: c.text,
      ),
      // 鸿蒙的按压反馈由 AppPressable 统一提供，不用 Material 水波纹。
      splashFactory: NoSplash.splashFactory,
      highlightColor: c.text.withValues(alpha: 0.05),
      hoverColor: Colors.transparent,
      dividerColor: c.divider,
      canvasColor: c.page,
      fontFamily: null,
      visualDensity: VisualDensity.standard,
      // 全站统一微信式转场：整屏推入 + 旧页 30% 视差，纯位移。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: WeChatPageTransitionsBuilder(),
          TargetPlatform.iOS: WeChatPageTransitionsBuilder(),
          TargetPlatform.macOS: WeChatPageTransitionsBuilder(),
          TargetPlatform.windows: WeChatPageTransitionsBuilder(),
          TargetPlatform.linux: WeChatPageTransitionsBuilder(),
          TargetPlatform.fuchsia: WeChatPageTransitionsBuilder(),
        },
      ),
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
      // 鸿蒙标准按钮：40 高、20 圆角、16 Medium。
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, AppSize.button),
          textStyle: const TextStyle(
            fontSize: AppFontSize.body,
            fontWeight: AppWeight.medium,
          ),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.accent,
          textStyle: const TextStyle(
            fontSize: AppFontSize.body,
            fontWeight: AppWeight.regular,
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.text,
        contentTextStyle: TextStyle(
          color: c.page,
          fontSize: AppFontSize.label,
          fontWeight: AppWeight.regular,
        ),
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        // SnackBar 底色是「反色」，普通 accent 在上面只有约 2:1，
        // 这里换成专门的反色强调（浅色深底用亮蓝、深色浅底用深蓝）。
        actionTextColor: c.inverseAccent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.button)),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalBackgroundColor: c.page,
        modalElevation: 0,
        shape: const RoundedSuperellipseBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.sheet),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.page,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(AppRadius.sheet),
        ),
        titleTextStyle: TextStyle(
          color: c.text,
          fontSize: AppFontSize.subtitle,
          fontWeight: AppWeight.medium,
        ),
        contentTextStyle: TextStyle(
          color: c.secondary,
          fontSize: AppFontSize.labelLg,
          height: 1.5,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.page,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(AppRadius.button),
        ),
        textStyle: TextStyle(
          color: c.text,
          fontSize: AppFontSize.summary,
          fontWeight: AppWeight.regular,
        ),
      ),
    );
  }
}

/// 微信 / iOS 式页面转场：新页整屏从右侧推入，旧页向左让出 30%。
///
/// 纯位移合成，没有透明度、缩放或模糊 —— 这是微信、微博等国内主流 App
/// 最常用的转场，低端机上最稳。进入用接近 iOS 的 `cubic-bezier(0.32,
/// 0.72, 0, 1)`，返回用加速曲线，退出更利落。
class WeChatPageTransitionsBuilder extends PageTransitionsBuilder {
  const WeChatPageTransitionsBuilder();

  /// 旧页向左让出的比例（视差）。
  static const double _parallax = 0.3;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final Animation<double> enter = CurvedAnimation(
      parent: animation,
      curve: const Cubic(0.32, 0.72, 0, 1),
      reverseCurve: Curves.easeInCubic,
    );
    final Animation<double> exit = CurvedAnimation(
      parent: secondaryAnimation,
      curve: const Cubic(0.32, 0.72, 0, 1),
      reverseCurve: Curves.easeInCubic,
    );

    return SlideTransition(
      // 新页：屏幕右侧外部 → 原位。
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(enter),
      child: SlideTransition(
        // 旧页：原位 → 左移 30%，形成前后层次。
        position: Tween<Offset>(
          begin: Offset.zero,
          end: const Offset(-_parallax, 0),
        ).animate(exit),
        child: child,
      ),
    );
  }
}

/// 回弹滚动 + 去掉 Android 的拉伸/发光指示器。
///
/// 在 `MaterialApp.scrollBehavior` 挂一次，所有可滚动区域自动生效；
/// 后续 Pad/PC 端要换成鼠标滚轮策略时，也只需要改这一个类。
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const BouncingScrollPhysics(
      parent: AlwaysScrollableScrollPhysics(),
    );
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}
