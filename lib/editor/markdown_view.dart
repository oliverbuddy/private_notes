import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../ui/tag_palette.dart';
import '../ui/task_check_box.dart';

/// 阅读态渲染：把 markdown 源码变成「没有记号」的排版文本。
///
/// 和编辑态的 [MarkdownEditingController] 是两套东西：
/// - 编辑态只给记号**降饱和度**，因为字符还在文本里，删了光标就对不上；
/// - 阅读态把记号直接**从输出里去掉**，用户看到的是一段干净的排版文字。
///
/// 两者共用同一份语法规则，改规则时要同时看。
class MarkdownBlockView extends StatelessWidget {
  const MarkdownBlockView({
    super.key,
    required this.text,
    required this.baseSize,
    this.onTap,
    this.onToggleTodo,
  });

  final String text;
  final double baseSize;

  /// 点击回调，带**全局坐标**：编辑页用它把光标定位到点击位置
  /// （阅读态点正文进编辑态时，光标应该落在手指点的那句话附近，
  /// 而不是块尾 —— 用户实测反馈过「再点一次才到点击处」）。
  final void Function(Offset globalPosition)? onTap;

  /// 不为空时待办渲染成可点选的 checkbox，点第 n 个待办回调 n
  /// （详情页阅读态直接勾选，不必进编辑态）。
  final void Function(int todoIndex)? onToggleTodo;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final base = TextStyle(
      fontSize: baseSize,
      height: 1.7,
      color: colors.text,
      fontWeight: AppWeight.regular,
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return GestureDetector(
          // onTap 为空（列表摘要）时不能吞事件，否则卡片本身的点击
          // （进入详情页）会被这层 GestureDetector 吃掉。
          behavior: onTap == null
              ? HitTestBehavior.deferToChild
              : HitTestBehavior.opaque,
          onTapUp: onTap == null
              ? null
              : (TapUpDetails details) => onTap!(details.globalPosition),
          child: Text.rich(
            TextSpan(
              children: markdownSpans(
                text,
                base,
                colors,
                onToggleTodo: onToggleTodo,
                codeBlockWidth:
                    constraints.hasBoundedWidth ? constraints.maxWidth : null,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 把一段 markdown 转成阅读态 span。
///
/// [headingBoost] 用来在列表摘要里压低标题的放大倍数：详情页 H1 是正文的
/// 1.5 倍很合理，但列表里一行 25px 的标题夹在 16px 正文中间，行高会跳得像
/// 排版事故。摘要传 0.86；同时标题字号有「不小于正文」的下限，避免 H3
/// 被压到比正文还小（整页看起来像等比缩小）。
List<InlineSpan> markdownSpans(
  String markdown,
  TextStyle base,
  AppColors colors, {
  double headingBoost = 1.0,

  /// 不为空时，待办渲染成可点选的真 checkbox，第 n 个待办被点击时回调 n；
  /// 为空（列表摘要）渲染字符字形。
  void Function(int todoIndex)? onToggleTodo,

  /// 代码块整宽容器的可用宽度。为空（没有布局约束的调用方）时退回
  /// 逐行字符底色；有宽度时渲染成与详情页一致的整宽圆角卡片。
  double? codeBlockWidth,
}) {
  // 结果缓存：键盘弹出动画的每一帧都会重建可见块（MediaQuery 逐帧变化），
  // 而 text 没变 —— 不缓存的话每帧都要对整块做几十次正则匹配，真机上
  // 键盘动画肉眼可见地卡。TextSpan 不可变，整树复用安全；span 里捕获的
  // 回调（勾选待办/点击聚焦）都指向同一个 entry，缓存不影响行为。
  final cacheKey = '$markdown\x1F${base.fontSize}\x1F${base.color}\x1F'
      '${identityHashCode(colors)}\x1F$headingBoost\x1F${onToggleTodo != null}'
      '\x1F${codeBlockWidth ?? 0}';
  final cached = _spansCache[cacheKey];
  if (cached != null) {
    return cached;
  }

  final spans = <InlineSpan>[];
  final baseSize = base.fontSize ?? 17;
  // 代码围栏不是「见到 ``` 就切换」：代码内容本身可能含 ```（写入时围栏
  // 会自动加长成 ````），见到就切换会把后半段代码渲染成正文。这里记录
  // 开启围栏的字符与长度，只有「同字符、长度不小于开启围栏、且后面没有
  // 其它内容」的行才算闭合 —— 与序列化器 _codeFenceFor 的规则一致。
  String? fenceChar;
  var fenceLength = 0;
  final RegExp fenceLine = RegExp(r'^([`~]{3,})([^`~]*)$');
  List<String>? codeLines;
  // 待办序号计数器：回调按「块内第几个待办」定位要翻转的行。
  var todoCounter = 0;
  final lines = markdown.split('\n');

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final isLast = i == lines.length - 1;
    final newline = isLast ? '' : '\n';

    // 代码块：与详情页同一套视觉 —— 整宽 surface2 圆角卡片 + 等宽文本。
    // 旧实现是「逐行字符底色」，只覆盖到文字宽度、没有圆角，和详情页的
    // 整宽容器明显不一致（用户多轮反馈「详情和列表效果不一致」）。
    final RegExpMatch? fence = fenceLine.firstMatch(line.trimLeft());
    if (fence != null &&
        (fenceChar == null ||
            (fence.group(1)![0] == fenceChar &&
                fence.group(1)!.length >= fenceLength))) {
      final bool opening = fenceChar == null;
      if (opening) {
        fenceChar = fence.group(1)![0];
        fenceLength = fence.group(1)!.length;
        codeLines = <String>[];
      } else {
        if (codeLines != null) {
          _appendCodeBlock(spans, codeLines, base, colors, codeBlockWidth);
        }
        codeLines = null;
        fenceChar = null;
        fenceLength = 0;
      }
      continue;
    }
    if (fenceChar != null) {
      codeLines?.add(line);
      continue;
    }

    // 分隔线：细划线字符 + 大字距，比一排粗横线轻盈（span 画不了真线）。
    if (RegExp(r'^\s*(?:-{3,}|\*{3,}|_{3,})\s*$').hasMatch(line)) {
      spans.add(TextSpan(
        text: '  ─────────────────  $newline',
        style: base.copyWith(
          color: colors.dividerStrong,
          fontSize: (base.fontSize ?? 17) * 0.7,
          height: 2.2,
          letterSpacing: 2,
        ),
      ));
      continue;
    }

    // 标题
    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
    if (heading != null) {
      final level = heading.group(1)!.length;
      final scales = <double>[1.5, 1.38, 1.26, 1.15, 1.08, 1.0];
      // 预览态（headingBoost < 1）里标题不能被压到比正文还小：H1 21 × 0.86
      // 还有 18，但 H3 16.5 × 0.86 = 14.2，比正文 15.5 更小 —— 整页会
      // 看起来像被「等比缩小」了一档（用户反馈）。主流列表方案是正文与
      // 详情同字号、标题只收敛层级，所以这里给标题兜一个正文字号下限。
      final double scaledSize = baseSize * scales[level - 1] * headingBoost;
      final double titleSize = scaledSize < baseSize ? baseSize : scaledSize;
      final style = base.copyWith(
        fontSize: titleSize,
        // 中文标题用 600 才立得住，500 和正文的粗细差几乎看不出来。
        fontWeight: AppWeight.semibold,
        height: 1.45,
        letterSpacing: 0.2,
      );
      // 段前空档：标题贴着上一行正文挤在一起是国内阅读排版的大忌
      // （语雀/微信读书都在标题前留呼吸空间）。作者没写空行时补一行，
      // 相当于自动排版；上一行本来就是空行则不重复加。
      // 列表摘要（headingBoost < 1）不加：列表里空行白吃一整行高度。
      // 注意这只影响阅读态的展示文本，不会回写笔记内容。
      if (headingBoost >= 1.0 && i > 0 && lines[i - 1].trim().isNotEmpty) {
        spans.add(TextSpan(text: '\n', style: base));
      }
      spans.addAll(_inline(heading.group(2)!, style, colors));
      spans.add(TextSpan(text: newline, style: style));
      continue;
    }

    // 引用：竖条 + 整行浅底（语雀样式）。中文没有真斜体字面（伪斜是字体
    // 强扭的），所以不用 fontStyle —— 国内阅读类产品引用一律不斜体。
    // 行内首尾各垫一个空格，让底色块有左右留白（span 做不了 padding）。
    final quote = RegExp(r'^\s*>\s?(.*)$').firstMatch(line);
    if (quote != null) {
      final style = base.copyWith(
        // 与详情页引用块同一个文字浓度（AppQuote 用 0.8）。
        color: colors.text.withValues(alpha: 0.8),
        backgroundColor: colors.accentBg,
        height: 1.6,
      );
      spans.add(TextSpan(
        text: ' ▍',
        style: style.copyWith(color: colors.accent.withValues(alpha: 0.55)),
      ));
      spans.add(const TextSpan(text: ' '));
      spans.addAll(_inline(quote.group(1)!, style, colors));
      spans.add(TextSpan(text: '$newline ', style: style));
      continue;
    }

    // 待办
    final todo = RegExp(r'^(\s*)[-*+]\s\[([ xX])\]\s*(.*)$').firstMatch(line);
    if (todo != null) {
      final checked = todo.group(2)!.toLowerCase() == 'x';
      final style = base.copyWith(
        color: checked ? colors.tertiary : colors.text,
        decoration: checked ? TextDecoration.lineThrough : TextDecoration.none,
      );
      // 阅读态（调用方给了 onToggleTodo）渲染成真 checkbox：直接点选切换，
      // 不必进编辑态手改 [ ] 记号 —— 语雀/Notion 同款交互。
      // 首页摘要（无回调）用**同一个**勾选框组件（不可点），保证两处视觉
      // 完全一致；之前摘要用 ☐/☑ 字符，和详情里的方框差得很明显（用户反馈）。
      // 行首缩进先补上，嵌套项的整行（含勾选框）一起右移。
      if (todo.group(1)!.isNotEmpty) {
        spans.add(TextSpan(text: todo.group(1), style: base));
      }
      final int? todoIndex = onToggleTodo == null ? null : todoCounter++;
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Padding(
          // 与详情页记号列同一套几何：左 4 + 框 20 + 间距 6（见 AppListMarker）。
          padding: const EdgeInsets.only(
            left: 4,
            right: TaskCheckBox.gap,
            top: 2,
            bottom: 2,
          ),
          child: TaskCheckBox(
            checked: checked,
            onTap: todoIndex == null ? null : () => onToggleTodo!(todoIndex),
          ),
        ),
      ));
      spans.addAll(_inline(todo.group(3)!, style, colors));
      spans.add(TextSpan(text: newline, style: style));
      continue;
    }

    // 无序列表：层级用符号区分（• → ◦ → ▪），对齐 Notion/微信的主流通行做法。
    final bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$').firstMatch(line);
    if (bullet != null) {
      final level = _listLevel(bullet.group(1)!);
      // 同待办：行首缩进保留，嵌套项视觉上退一格。
      if (bullet.group(1)!.isNotEmpty) {
        spans.add(TextSpan(text: bullet.group(1), style: base));
      }
      spans.add(TextSpan(
        text: '${_bulletGlyph(level)}  ',
        style: base.copyWith(color: colors.secondary),
      ));
      spans.addAll(_inline(bullet.group(2)!, base, colors));
      spans.add(TextSpan(text: newline, style: base));
      continue;
    }

    // 有序列表：编号分层（1. → a. → i.），Word/Typora/Notion 的通行方案。
    // 只改**显示**，不改 md 源码 —— 源码里仍是合法的十进制编号，往返无损。
    final ordered = RegExp(r'^(\s*)(\d+)([.)])\s+(.*)$').firstMatch(line);
    if (ordered != null) {
      final level = _listLevel(ordered.group(1)!);
      final number = int.tryParse(ordered.group(2)!) ?? 1;
      final marker = _orderedMarker(number, level);
      // 同待办：行首缩进保留，嵌套项视觉上退一格。
      if (ordered.group(1)!.isNotEmpty) {
        spans.add(TextSpan(text: ordered.group(1), style: base));
      }
      spans.add(TextSpan(
        text: '$marker${ordered.group(3)}  ',
        style: base.copyWith(color: colors.secondary),
      ));
      spans.addAll(_inline(ordered.group(4)!, base, colors));
      spans.add(TextSpan(text: newline, style: base));
      continue;
    }

    spans.addAll(_inline(line, base, colors));
    spans.add(TextSpan(text: newline, style: base));
  }

  // 文档末尾没有闭合围栏时，把已收集的代码行也渲染出来，避免内容消失。
  if (codeLines != null) {
    _appendCodeBlock(spans, codeLines, base, colors, codeBlockWidth);
  }

  if (_spansCache.length >= _spansCacheLimit) {
    _spansCache.clear();
  }
  _spansCache[cacheKey] = spans;
  return spans;
}

/// 阅读态 span 缓存（见 markdownSpans 内注释）。容量按「一屏可见块数」的
/// 几倍取，超限整体清空 —— 比逐条 LRU 简单，miss 率也足够低。
final Map<String, List<InlineSpan>> _spansCache = <String, List<InlineSpan>>{};
const int _spansCacheLimit = 24;

/// 代码块卡片规格：详情页（编辑器）与列表摘要共用。
///
/// 两处原来是各写一套字面量，改一处忘一处就会「列表和详情看起来不一样」
/// （用户多轮反馈）。统一收在这里：内边距 12/10、上下间距 6、字号 ×0.9、
/// 行高 1.55、文字 85% 浓度 —— 详情与列表只共用这一份。
abstract final class CodeBlockCardStyle {
  static const double paddingHorizontal = 12;
  static const double paddingVertical = 10;

  /// 卡片与上下相邻块的间距。
  static const double outerGap = 6;

  /// 字号相对正文的缩放（正文 16 → 14.4）。
  static const double fontSizeFactor = 0.9;

  static const double lineHeight = 1.55;

  /// 代码文字浓度：比正文略淡，弱化一整块等宽字。
  static const double textAlpha = 0.85;
}

/// 代码块行样式：等宽 + 微缩。底色由调用方负责（整宽容器 / fallback 底色）。
TextStyle _codeBase(TextStyle base, AppColors colors) {
  return base.copyWith(
    fontFamily: 'monospace',
    fontSize: (base.fontSize ?? 17) * CodeBlockCardStyle.fontSizeFactor,
    height: CodeBlockCardStyle.lineHeight,
    // 与详情页同一套行盒分布，中文在卡片里的上下留白才一致。
    leadingDistribution: TextLeadingDistribution.even,
    color: colors.text.withValues(alpha: CodeBlockCardStyle.textAlpha),
  );
}

/// 把收集到的代码行渲染成一个整宽圆角卡片。
///
/// [width] 来自外层 [LayoutBuilder]：有宽度时用 [WidgetSpan] 撑满一行，
/// 与详情页的代码块容器保持同一视觉；没有宽度（直接调用 markdownSpans 的
/// 老场景）退回逐行字符底色，至少保证等宽与浅底不丢。
void _appendCodeBlock(
  List<InlineSpan> spans,
  List<String> lines,
  TextStyle base,
  AppColors colors,
  double? width,
) {
  final TextStyle codeStyle = _codeBase(base, colors);
  if (width == null || width <= 0) {
    for (var i = 0; i < lines.length; i++) {
      final String suffix = i == lines.length - 1 ? '' : '\n';
      spans.add(TextSpan(
        text: ' ${lines[i]}$suffix',
        style: codeStyle.copyWith(backgroundColor: colors.surface2),
      ));
    }
    spans.add(TextSpan(
      text: '\n',
      style: codeStyle.copyWith(backgroundColor: colors.surface2),
    ));
    return;
  }
  spans.add(WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: Container(
      width: width,
      margin: const EdgeInsets.symmetric(
        vertical: CodeBlockCardStyle.outerGap,
      ),
      // 内边距与详情页卡片同源（见 [CodeBlockCardStyle]）。
      padding: const EdgeInsets.symmetric(
        horizontal: CodeBlockCardStyle.paddingHorizontal,
        vertical: CodeBlockCardStyle.paddingVertical,
      ),
      decoration: BoxDecoration(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.block),
      ),
      child: Text(lines.join('\n'), style: codeStyle),
    ),
  ));
}

final RegExp _inlinePattern = RegExp(
  r'\*\*([^*\n]+)\*\*'
  r'|~~([^~\n]+)~~'
  r'|`([^`\n]+)`'
  r'|\[([^\]\n]*)\]\(([^)\n]*)\)'
  r'|\*([^*\n]+)\*'
  r'|#([^\s#，。！？、,.!?]+)'
  r'|==([^=\n]+)==',
);

List<InlineSpan> _inline(String text, TextStyle style, AppColors colors) {
  final spans = <InlineSpan>[];
  var last = 0;
  for (final match in _inlinePattern.allMatches(text)) {
    if (match.start > last) {
      spans
          .add(TextSpan(text: text.substring(last, match.start), style: style));
    }
    final bold = match.group(1);
    final strike = match.group(2);
    final code = match.group(3);
    final linkText = match.group(4);
    final italic = match.group(6);
    final tag = match.group(7);
    final highlight = match.group(8);

    if (bold != null) {
      // 正文强调用 600：中文 500 与 400 的字面差几乎看不见（见 AppWeight 注释）。
      spans.add(TextSpan(
        text: bold,
        style: style.copyWith(fontWeight: AppWeight.semibold),
      ));
    } else if (strike != null) {
      spans.add(TextSpan(
        text: strike,
        style: style.copyWith(
          decoration: TextDecoration.lineThrough,
          color: colors.tertiary,
        ),
      ));
    } else if (code != null) {
      // 行内码微缩一档（主流排版做法），等宽字形在小字号下更协调。
      spans.add(TextSpan(
        text: code,
        style: style.copyWith(
          fontFamily: 'monospace',
          fontSize: (style.fontSize ?? 17) * 0.9,
          backgroundColor: colors.surface2,
          color: colors.text.withValues(alpha: 0.9),
        ),
      ));
    } else if (linkText != null) {
      spans.add(TextSpan(
        text: linkText,
        style: style.copyWith(
          color: colors.accent,
          decoration: TextDecoration.underline,
          decorationColor: colors.accent,
        ),
      ));
    } else if (italic != null) {
      spans.add(TextSpan(
          text: italic, style: style.copyWith(fontStyle: FontStyle.italic)));
    } else if (highlight != null) {
      // `==高亮==`：与编辑器 inlineTextStyler 同一套底色，逐字可读。
      spans.add(TextSpan(
        text: highlight,
        style: style.copyWith(backgroundColor: colors.accentBg),
      ));
    } else if (tag != null) {
      // 标签胶囊按「正文里的行内标记」处理：字号压到正文的 0.75
      // （约 12），左右留 3、圆角与详情胶囊一致，高度约 17dp。
      // 主流笔记（语雀/滴答）的标签就是这种小标记，太大会比正文还抢眼。
      final double tagSize = (style.fontSize ?? 17) * 0.75;
      final TagTone tone = TagPalette.toneFor(tag, colors);
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0.5),
          decoration: BoxDecoration(
            color: tone.background,
            borderRadius: BorderRadius.circular(AppRadius.chip),
            border: Border.all(
              color: tone.border,
              width: 0.5,
            ),
          ),
          child: Text(
            '#$tag',
            style: TextStyle(
              fontSize: tagSize,
              // 行盒压到与详情胶囊同高（约 17dp）。
              height: 1.1,
              letterSpacing: 0.1,
              color: tone.foreground,
            ),
          ),
        ),
      ));
    } else {
      spans.add(TextSpan(text: match.group(0), style: style));
    }
    last = match.end;
  }
  if (last < text.length) {
    spans.add(TextSpan(text: text.substring(last), style: style));
  }
  return spans;
}

/// 列表层级：缩进命令每次加两个空格，两个空格算一层，封顶 3 层。
int _listLevel(String indent) => (indent.length ~/ 2).clamp(0, 3);

/// 无序列表各层符号：实心圆 → 空心圆 → 小方块（Notion/微信通行）。
String _bulletGlyph(int level) => switch (level) {
      0 => '•',
      1 => '◦',
      _ => '▪',
    };

/// 有序列表各层编号：十进制 → 小写字母 → 小写罗马（Word/Typora/Notion 通行）。
/// 只影响显示；源码里始终是合法的十进制编号。
String _orderedMarker(int number, int level) => switch (level) {
      1 => _alphaLabel(number),
      2 || 3 => _romanNumeral(number),
      _ => '$number',
    };

/// 1 → a, 2 → b, … 26 → z, 27 → aa（电子表格同款双字母进位）。
String _alphaLabel(int number) {
  var n = number;
  final out = StringBuffer();
  while (n > 0) {
    final rem = (n - 1) % 26;
    out.write(String.fromCharCode(0x61 + rem));
    n = (n - 1) ~/ 26;
  }
  return out.toString();
}

/// 1 → i, 4 → iv, 9 → ix, 14 → xiv …（标准减法记法，超 3999 回退十进制）。
String _romanNumeral(int number) {
  if (number <= 0 || number > 3999) {
    return '$number';
  }
  const values = <int, String>{
    1000: 'm',
    900: 'cm',
    500: 'd',
    400: 'cd',
    100: 'c',
    90: 'xc',
    50: 'l',
    40: 'xl',
    10: 'x',
    9: 'ix',
    5: 'v',
    4: 'iv',
    1: 'i',
  };
  var n = number;
  final out = StringBuffer();
  values.forEach((value, symbol) {
    while (n >= value) {
      out.write(symbol);
      n -= value;
    }
  });
  return out.toString();
}

/// 列表摘要的取样：取前若干行，去掉图片/附件独占行和代码围栏。
///
/// 摘要要和详情页长得一样，所以不能简单地剥成纯文本 —— 剥完标题就不是标题了。
/// 但也不能整篇渲染，图片语法会在列表里变成一串方括号。
///
/// **空行保留**：空行是用户有意留出的段落间隔，摘要里也必须看得见
/// （用户反复强调「不要把空白行去掉」）。空行和正文行一样占 [maxLines]
/// 的名额 —— 摘要按「最多显示几行」计算，空行也是一行。
String excerptSource(String markdown, {int maxLines = 6}) {
  final out = <String>[];
  for (final line in markdown.split('\n')) {
    if (line.trimLeft().startsWith('```')) {
      // 保留围栏：摘要也要交给 markdownSpans 渲染成代码块卡片。
      // 之前直接 continue 掉围栏，代码行到了摘要里就变成普通正文，
      // 列表里完全没有代码块效果（用户反馈）。
      out.add(line);
      if (out.length >= maxLines) {
        break;
      }
      continue;
    }
    // 只丢图片行。附件行 `[文件名](assets/…)` 要在摘要里显示成文件条目
    // （详情页是附件卡片），不能当普通文本删掉 —— 否则详情有卡片、
    // 列表里什么都没有（用户反馈两处不一致）。
    if (RegExp(r'^\s*!\[[^\]]*\]\([^)\s]+\)[ \t\r]*$').hasMatch(line)) {
      continue;
    }
    // 表格：摘要不画网格。分隔行（`| --- |`）直接丢，数据行压成
    // 「名称 · 数量」这样可扫读的一行 —— 否则列表里全是竖线和减号。
    if (_tableSeparatorLine.hasMatch(line.trim())) {
      continue;
    }
    // 首个内容出现之前的空行没有意义，丢掉；内容之间的空行原样保留。
    if (line.trim().isEmpty && out.isEmpty) {
      continue;
    }
    out.add(_flattenTableRow(line));
    if (out.length >= maxLines) {
      break;
    }
  }
  while (out.isNotEmpty && out.last.trim().isEmpty) {
    out.removeLast();
  }
  return out.join('\n');
}

/// GFM 表格分隔行：`| --- | :---: |` 这类全部由 `| - :` 与空白组成。
final RegExp _tableSeparatorLine = RegExp(r'^[|\s:-]+$');

/// 摘要里把表格数据行压成单行：`| 名称 | 数量 |` → `名称 · 数量`。
///
/// 只处理「以竖线开头或结尾、且至少两列」的行，普通文本里的 `a | b`
/// 原样返回，不误伤正文。
String _flattenTableRow(String line) {
  final String trimmed = line.trim();
  if (!trimmed.startsWith('|') && !trimmed.endsWith('|')) {
    return line;
  }
  final List<String> cells = trimmed
      .replaceAll(RegExp(r'^\||\|$'), '')
      .split('|')
      .map((String cell) => cell.trim())
      .where((String cell) => cell.isNotEmpty)
      .toList();
  if (cells.length < 2) {
    return line;
  }
  return cells.join(' · ');
}
