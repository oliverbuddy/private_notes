import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 只改样式、不改文本的 markdown 控制器。
///
/// 关键设计：输入框里存的永远是**原始 markdown**，我们只在 `buildTextSpan`
/// 里把语法符号换成「淡显色」。这样用户既看到了排版效果，又随时能改到
/// 每个字符 —— 不做富文本内部模型，是因为那会在「用户输入」和「文档模型」之间
/// 引入双向同步，是这类编辑器最常见的 bug 来源。
class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({super.text});

  /// 正文基准字号。标题按倍数放大，倍数直接取产品规范里的数值。
  static const double baseFontSize = 17;

  /// 与阅读态 `markdown_view.dart` 里的 scales 完全一致：
  /// 同一个标题在编辑态和阅读态必须一样大，否则点一下「完成」整篇会重排。
  static const List<double> _headingScales = <double>[
    1.5,
    1.38,
    1.26,
    1.15,
    1.08,
    1.0,
  ];

  // 全部静态编译。之前这些正则写在 _lineSpans/_inline 内部，每次按键
  // 都要为每一行重新编译 5-6 个 RegExp（Dart 的正则编译走 native，很贵），
  // 一篇 30 行的笔记打一个字要做 200+ 次编译 —— 真机上明显卡顿。
  static final RegExp _hrPattern = RegExp(r'^\s*(?:-{3,}|\*{3,}|_{3,})\s*$');
  static final RegExp _headingPattern = RegExp(r'^(#{1,6})(\s+)(.*)$');
  static final RegExp _todoPattern = RegExp(r'^(\s*)(- \[[ xX]\]\s*)(.*)$');
  static final RegExp _todoCheckedPattern = RegExp(r'\[[xX]\]');
  static final RegExp _quotePattern = RegExp(r'^(>\s?)(.*)$');
  static final RegExp _bulletPattern = RegExp(r'^(\s*)([-*+]\s+)(.*)$');
  static final RegExp _orderedPattern = RegExp(r'^(\s*)(\d+[.)]\s+)(.*)$');

  /// `#` 后面紧跟字母/数字/汉字才算标签，避免和标题、纯符号混淆。
  static bool _isTagChar(int codeUnit) {
    const a = 0x61;
    const z = 0x7A;
    const upperA = 0x41;
    const upperZ = 0x5A;
    const zero = 0x30;
    const nine = 0x39;
    const underscore = 0x5F;
    const cjkStart = 0x4E00;
    const cjkEnd = 0x9FFF;
    return (codeUnit >= a && codeUnit <= z) ||
        (codeUnit >= upperA && codeUnit <= upperZ) ||
        (codeUnit >= zero && codeUnit <= nine) ||
        codeUnit == underscore ||
        (codeUnit >= cjkStart && codeUnit <= cjkEnd);
  }

  // span 结果缓存：text 没变就整树复用。
  //
  // buildTextSpan 不只在打字时被调用 —— 光标移动、键盘弹出动画的每一帧、
  // 任何导致 TextField 重建的 setState 都会触发。一棵 span 树对 30 行的
  // 笔记要做上百次正则匹配，而这些场景里 text 根本没变。TextSpan 是
  // 不可变的，复用完全安全；composing 下划线分支也是基于缓存生成新列表。
  String? _spanCacheText;
  TextStyle? _spanCacheBase;
  AppColors? _spanCacheColors;
  List<InlineSpan>? _spanCache;

  List<InlineSpan> _buildSpansCached(
    String text,
    TextStyle base,
    AppColors colors,
  ) {
    final cached = _spanCache;
    if (cached != null &&
        _spanCacheText == text &&
        _spanCacheBase == base &&
        identical(_spanCacheColors, colors)) {
      return cached;
    }
    final spans = _buildSpans(text, base, colors);
    _spanCacheText = text;
    _spanCacheBase = base;
    _spanCacheColors = colors;
    _spanCache = spans;
    return spans;
  }

  /// 某一级标题（1-6）相对正文的字号倍数，供光标高度匹配当前行字号用。
  static double headingScale(int level) {
    if (level < 1 || level > _headingScales.length) {
      return 1.0;
    }
    return _headingScales[level - 1];
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final colors = AppColors.of(context);
    final base = style ?? const TextStyle();

    final spans = _buildSpansCached(text, base, colors);

    // 组词期间以前是整段交回默认实现（朴素样式）—— 换来的是「英文单词打到
    // 一半、整个标题突然变回正文字号」的跳变。现在自己给组词区加下划线：
    // 样式照常生效，输入法的组词提示也还在。
    final TextRange composing = value.composing;
    if (withComposing && composing.isValid && !composing.isCollapsed) {
      return TextSpan(
        style: base,
        children: _withComposingUnderline(spans, composing),
      );
    }

    return TextSpan(style: base, children: spans);
  }

  /// 给 [composing] 区间叠加下划线，其余样式保持不变。
  ///
  /// span 是逐字符拼出来的（见 [_buildSpans]），所以这里按偏移切开再拼回去，
  /// 不会改变任何字符 —— 否则光标偏移就和文本对不上了。
  static List<InlineSpan> _withComposingUnderline(
    List<InlineSpan> spans,
    TextRange composing,
  ) {
    final result = <InlineSpan>[];
    var offset = 0;
    for (final span in spans) {
      if (span is! TextSpan || span.text == null) {
        result.add(span);
        continue;
      }
      final String content = span.text!;
      final int start = offset;
      final int end = offset + content.length;
      offset = end;
      final int from = composing.start.clamp(start, end);
      final int to = composing.end.clamp(start, end);
      if (from >= to) {
        result.add(span);
        continue;
      }
      final String head = content.substring(0, from - start);
      final String middle = content.substring(from - start, to - start);
      final String tail = content.substring(to - start);
      if (head.isNotEmpty) {
        result.add(TextSpan(text: head, style: span.style));
      }
      result.add(
        TextSpan(
          text: middle,
          style: (span.style ?? const TextStyle()).copyWith(
            decoration: TextDecoration.underline,
            decorationColor: span.style?.color ?? const Color(0xFF7DB2FF),
          ),
        ),
      );
      if (tail.isNotEmpty) {
        result.add(TextSpan(text: tail, style: span.style));
      }
    }
    return result;
  }

  /// 逐行构建。**必须**一个字符不落地发出 span，
  /// 否则光标位置和文本偏移会对不上。
  List<InlineSpan> _buildSpans(
    String source,
    TextStyle base,
    AppColors colors,
  ) {
    final spans = <InlineSpan>[];
    if (source.isEmpty) {
      return spans;
    }

    var cursor = 0;
    var inFence = false;

    while (true) {
      final newline = source.indexOf('\n', cursor);
      final end = newline < 0 ? source.length : newline;
      final line = source.substring(cursor, end);
      final trimmedLeft = line.trimLeft();

      if (trimmedLeft.startsWith('```')) {
        spans.add(
          TextSpan(
            text: line,
            style: _codeStyle(base, colors, marker: true),
          ),
        );
        inFence = !inFence;
      } else if (inFence) {
        spans.add(
          TextSpan(
            text: line,
            style: _codeStyle(base, colors, marker: false),
          ),
        );
      } else {
        spans.addAll(_lineSpans(line, base, colors));
      }

      if (newline < 0) {
        break;
      }
      spans.add(TextSpan(text: '\n', style: base));
      cursor = newline + 1;
    }

    return spans;
  }

  TextStyle _codeStyle(TextStyle base, AppColors colors, {required bool marker}) {
    return base.copyWith(
      fontFamily: 'monospace',
      fontFamilyFallback: const <String>['Menlo', 'Courier New', 'Courier'],
      fontSize: (base.fontSize ?? baseFontSize) * 0.94,
      backgroundColor: colors.surface2,
      color: marker ? colors.syntaxMarker : base.color,
    );
  }

  TextStyle _markerStyle(TextStyle base, AppColors colors) {
    // copyWith 无法把字段设回 null，所以用透明背景 + none 装饰来「清空」继承来的样式。
    // 记号压到 40% 不透明度：光标行几乎看不见 md 标记（语雀所见即所得的观感），
    // 但字符仍在，光标偏移/选区完全正确 —— 这是「不存内部结构模型」约束下
    // 能做到的最接近语雀的方案。
    return base.copyWith(
      color: colors.syntaxMarker.withValues(alpha: 0.40),
      fontWeight: AppWeight.regular,
      fontStyle: FontStyle.normal,
      decoration: TextDecoration.none,
      backgroundColor: Colors.transparent,
    );
  }

  /// 行级语法：标题 / 待办 / 列表 / 引用 / 分隔线。
  List<InlineSpan> _lineSpans(String line, TextStyle base, AppColors colors) {
    if (line.isEmpty) {
      return const <InlineSpan>[];
    }

    // 分隔线：整行都当符号处理。
    if (_hrPattern.hasMatch(line)) {
      return <InlineSpan>[
        TextSpan(
          text: line,
          style: base.copyWith(color: colors.syntaxMarker),
        ),
      ];
    }

    // 标题 `# ` ~ `###### `
    final heading = _headingPattern.firstMatch(line);
    if (heading != null) {
      final level = heading.group(1)!.length;
      final scale = _headingScales[level - 1];
      final size = (base.fontSize ?? baseFontSize) * scale;
      final headingStyle = base.copyWith(
        fontSize: size,
        fontWeight: AppWeight.semibold,
        height: 1.38,
      );
      return <InlineSpan>[
        TextSpan(
          text: heading.group(1)!,
          style: _markerStyle(headingStyle, colors),
        ),
        TextSpan(
          text: heading.group(2)!,
          style: _markerStyle(headingStyle, colors),
        ),
        ..._inline(heading.group(3)!, headingStyle, colors),
      ];
    }

    // 待办 `- [ ] ` / `- [x] `
    final todo = _todoPattern.firstMatch(line);
    if (todo != null) {
      final checked = todo.group(2)!.contains(_todoCheckedPattern);
      final contentStyle = checked
          ? base.copyWith(
              color: colors.tertiary,
              decoration: TextDecoration.lineThrough,
              decorationColor: colors.tertiary,
            )
          : base;
      return <InlineSpan>[
        TextSpan(text: todo.group(1)!, style: base),
        TextSpan(
          text: todo.group(2)!,
          style: base.copyWith(
            color: checked ? colors.tertiary : colors.accent,
          ),
        ),
        ..._inline(todo.group(3)!, contentStyle, colors),
      ];
    }

    // 引用 `> `
    final quote = _quotePattern.firstMatch(line);
    if (quote != null) {
      return <InlineSpan>[
        TextSpan(text: quote.group(1)!, style: _markerStyle(base, colors)),
        ..._inline(
          quote.group(2)!,
          base.copyWith(
            fontStyle: FontStyle.italic,
            color: colors.secondary,
          ),
          colors,
        ),
      ];
    }

    // 无序列表 `- ` `* ` `+ `
    final bullet = _bulletPattern.firstMatch(line);
    if (bullet != null) {
      return <InlineSpan>[
        TextSpan(text: bullet.group(1)!, style: base),
        TextSpan(
          text: bullet.group(2)!,
          style: base.copyWith(color: colors.accent),
        ),
        ..._inline(bullet.group(3)!, base, colors),
      ];
    }

    // 有序列表 `1. ` / `1) `
    final ordered = _orderedPattern.firstMatch(line);
    if (ordered != null) {
      return <InlineSpan>[
        TextSpan(text: ordered.group(1)!, style: base),
        TextSpan(
          text: ordered.group(2)!,
          style: base.copyWith(color: colors.accent),
        ),
        ..._inline(ordered.group(3)!, base, colors),
      ];
    }

    return _inline(line, base, colors);
  }

  /// 行内语法：粗体 / 斜体 / 行内码 / 链接 / 删除线 / #标签。
  List<InlineSpan> _inline(String text, TextStyle style, AppColors colors) {
    if (text.isEmpty) {
      return const <InlineSpan>[];
    }

    final out = <InlineSpan>[];
    final buffer = StringBuffer();

    void flush() {
      if (buffer.isEmpty) {
        return;
      }
      out.add(TextSpan(text: buffer.toString(), style: style));
      buffer.clear();
    }

    var i = 0;
    while (i < text.length) {
      // 代理对（emoji 等）必须整段取出来：按 code unit 切会把一个字符
      // 拆进两个 span，粗体里带 emoji 时会渲染成乱码方块。
      final codeUnit = text.codeUnitAt(i);
      final char =
          (codeUnit >= 0xD800 && codeUnit <= 0xDFFF && i + 1 < text.length)
              ? text.substring(i, i + 2)
              : text[i];

      // 粗体 `**...**`
      if (char == '*' && i + 1 < text.length && text[i + 1] == '*') {
        final close = text.indexOf('**', i + 2);
        if (close > i + 2) {
          flush();
          out.add(TextSpan(text: '**', style: _markerStyle(style, colors)));
          out.addAll(
            _inline(
              text.substring(i + 2, close),
              style.copyWith(fontWeight: AppWeight.semibold),
              colors,
            ),
          );
          out.add(TextSpan(text: '**', style: _markerStyle(style, colors)));
          i = close + 2;
          continue;
        }
      }

      // 斜体 `*...*`
      if (char == '*') {
        final close = text.indexOf('*', i + 1);
        if (close > i + 1) {
          flush();
          out.add(TextSpan(text: '*', style: _markerStyle(style, colors)));
          out.addAll(
            _inline(
              text.substring(i + 1, close),
              style.copyWith(fontStyle: FontStyle.italic),
              colors,
            ),
          );
          out.add(TextSpan(text: '*', style: _markerStyle(style, colors)));
          i = close + 1;
          continue;
        }
      }

      // 行内码 `` `...` ``
      if (char == '`') {
        final close = text.indexOf('`', i + 1);
        if (close > i + 1) {
          flush();
          out.add(TextSpan(text: '`', style: _markerStyle(style, colors)));
          out.add(
            TextSpan(
              text: text.substring(i + 1, close),
              style: style.copyWith(
                fontFamily: 'monospace',
                fontFamilyFallback: const <String>['Menlo', 'Courier New'],
                backgroundColor: colors.surface2,
                fontSize: (style.fontSize ?? baseFontSize) * 0.94,
              ),
            ),
          );
          out.add(TextSpan(text: '`', style: _markerStyle(style, colors)));
          i = close + 1;
          continue;
        }
      }

      // 删除线 `~~...~~`
      if (char == '~' && i + 1 < text.length && text[i + 1] == '~') {
        final close = text.indexOf('~~', i + 2);
        if (close > i + 2) {
          flush();
          out.add(TextSpan(text: '~~', style: _markerStyle(style, colors)));
          out.add(
            TextSpan(
              text: text.substring(i + 2, close),
              style: style.copyWith(
                decoration: TextDecoration.lineThrough,
                decorationColor: style.color,
              ),
            ),
          );
          out.add(TextSpan(text: '~~', style: _markerStyle(style, colors)));
          i = close + 2;
          continue;
        }
      }

      // 链接 `[文字](url)`
      if (char == '[') {
        final labelEnd = text.indexOf(']', i + 1);
        if (labelEnd > i && labelEnd + 1 < text.length && text[labelEnd + 1] == '(') {
          final urlEnd = text.indexOf(')', labelEnd + 2);
          if (urlEnd > labelEnd + 2) {
            flush();
            out.add(TextSpan(text: '[', style: _markerStyle(style, colors)));
            out.add(
              TextSpan(
                text: text.substring(i + 1, labelEnd),
                style: style.copyWith(
                  color: colors.accent,
                  decoration: TextDecoration.underline,
                  decorationColor: colors.accent,
                ),
              ),
            );
            out.add(
              TextSpan(
                text: text.substring(labelEnd, urlEnd + 1),
                style: _markerStyle(style, colors),
              ),
            );
            i = urlEnd + 1;
            continue;
          }
        }
      }

      // #标签：`#` 后面紧跟字母/数字/汉字才算，避免和标题、纯符号混淆。
      // 手写扫描而不是正则：这里在逐字符循环里，substring + 编译正则的
      // 开销是 O(n²) 级别的。
      if (char == '#') {
        var j = i + 1;
        while (j < text.length && _isTagChar(text.codeUnitAt(j))) {
          j++;
        }
        if (j > i + 1) {
          flush();
          out.add(
            TextSpan(
              text: text.substring(i, j),
              style: style.copyWith(color: colors.accent),
            ),
          );
          i = j;
          continue;
        }
      }

      buffer.write(char);
      i += char.length;
    }

    flush();
    return out;
  }
}
