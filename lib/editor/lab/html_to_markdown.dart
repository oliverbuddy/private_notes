/// 轻量 HTML → Markdown 转换。
///
/// 只覆盖剪贴板里最常见的语义标签（网页正文、富文本编辑器），不做完整
/// DOM 解析、不引入第三方依赖。规则与 Obsidian 的「粘贴 HTML 自动转
/// Markdown」一致：标题 / 段落 / 加粗 / 斜体 / 删除线 / 行内码 / 代码块 /
/// 链接 / 列表 / 引用 / 分隔线。
///
/// 远程图片不做 `![]()`：小记只渲染本地附件，远程图会变成坏图，这里转
/// 成普通链接保留信息。
String htmlToMarkdown(String html) {
  if (html.trim().isEmpty) {
    return '';
  }
  var s = html;
  // 注释、脚本、样式、head：只保留正文。
  s = s.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
  s = s.replaceAll(
    RegExp(r'<(script|style|head|noscript)[^>]*>[\s\S]*?</\1>',
        caseSensitive: false),
    '',
  );

  // 代码块先取出来并用占位符保护：代码里的 `<` `>` 不能被后面的「剥标签」
  // 规则当成 HTML 标签吃掉（实测 `a < b` 会变成 `a`）。
  final List<String> codeBlocks = <String>[];
  s = s.replaceAllMapped(
    RegExp(r'<pre[^>]*>([\s\S]*?)</pre>', caseSensitive: false),
    (Match m) {
      final String code = _decodeEntities(
        m.group(1)!.replaceAll(RegExp(r'<[^>]+>'), ''),
      ).trimRight();
      final String token = '\u0000CODE${codeBlocks.length}\u0000';
      codeBlocks.add(code);
      return '\n\n$token\n\n';
    },
  );

  // 引用块：内部先做行内转换，再逐行加 `> `。
  s = s.replaceAllMapped(
    RegExp(r'<blockquote[^>]*>([\s\S]*?)</blockquote>',
        caseSensitive: false),
    (Match m) {
      final String inner = _inline(
        m.group(1)!.replaceAll(
              RegExp(r'</?(p|div|section|article|br)[^>]*>',
                  caseSensitive: false),
              '\n',
            ),
      );
      final List<String> lines = inner
          .split('\n')
          .map((String line) => line.trim())
          .where((String line) => line.isNotEmpty)
          .map((String line) => '> $line')
          .toList();
      return '\n\n${lines.join('\n')}\n\n';
    },
  );

  // 标题（从 h6 到 h1 倒序替换，避免 h1 规则误伤 h10 之类）。
  for (int level = 6; level >= 1; level--) {
    s = s.replaceAllMapped(
      RegExp('<h$level[^>]*>([\\s\\S]*?)</h$level>',
          caseSensitive: false),
      (Match m) {
        final String title =
            _inline(m.group(1)!).replaceAll('\n', ' ').trim();
        return '\n\n${'#' * level} $title\n\n';
      },
    );
  }

  s = _convertLists(s);
  s = _inline(s);

  // 块级边界。
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  s = s.replaceAll(
    RegExp(r'</(p|div|section|article|header|footer|li|tr|h[1-6])>',
        caseSensitive: false),
    '\n\n',
  );
  s = s.replaceAll(RegExp(r'<hr\s*/?>', caseSensitive: false), '\n\n---\n\n');
  s = s.replaceAll(RegExp(r'<td[^>]*>', caseSensitive: false), ' | ');
  s = s.replaceAll(RegExp(r'<th[^>]*>', caseSensitive: false), ' | ');
  // 其余标签全部剥掉（div/span/table 等只保留内容）。
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');

  s = _decodeEntities(s);
  s = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  s = s.replaceAll(RegExp(r'[ \t]+\n'), '\n');
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  // 还原代码块占位符。
  for (int i = 0; i < codeBlocks.length; i++) {
    s = s.replaceAll('\u0000CODE$i\u0000', '```\n${codeBlocks[i]}\n```');
  }
  return s.trim();
}

/// 列表：`<ul>` 用 `- `，`<ol>` 用 `1. `。
///
/// 嵌套列表会被压平（受限于无 DOM 解析），但层级内容不会丢。
String _convertLists(String html) {
  var s = html;
  s = s.replaceAllMapped(
    RegExp(r'<ol\b[^>]*>([\s\S]*?)</ol>', caseSensitive: false),
    (Match m) {
      var index = 0;
      final String inner = m.group(1)!.replaceAllMapped(
        RegExp(r'<li\b[^>]*>', caseSensitive: false),
        (_) {
          index++;
          return '\n$index. ';
        },
      );
      return '\n$inner\n';
    },
  );
  s = s.replaceAll(RegExp(r'<ul\b[^>]*>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'</ul>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<li\b[^>]*>', caseSensitive: false), '\n- ');
  s = s.replaceAll(RegExp(r'</li>', caseSensitive: false), '');
  s = s.replaceAll(RegExp(r'</ol>', caseSensitive: false), '\n');
  return s;
}

/// 行内样式与链接。
String _inline(String html) {
  var s = html;

  // 链接：保留文字与 href；空文字时直接给出 URL。
  s = s.replaceAllMapped(
    RegExp(
      r'''<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>''',
      caseSensitive: false,
    ),
    (Match m) {
      final String href = m.group(1)!.trim();
      final String label = _plainText(m.group(2)!);
      if (href.isEmpty) {
        return label;
      }
      return label.isEmpty ? href : '[$label]($href)';
    },
  );

  // 图片：只保留为普通链接（远程图片无法落盘）。
  s = s.replaceAllMapped(
    RegExp(r'<img\b[^>]*>', caseSensitive: false),
    (Match m) {
      final String tag = m.group(0)!;
      final String? src = _attribute(tag, 'src');
      if (src == null || src.trim().isEmpty) {
        return '';
      }
      final String alt = _attribute(tag, 'alt') ?? '';
      return alt.trim().isEmpty
          ? '[$src]($src)'
          : '[${alt.trim()}]($src)';
    },
  );

  s = s.replaceAll(
      RegExp(r'<(strong|b)\b[^>]*>', caseSensitive: false), '**');
  s = s.replaceAll(RegExp(r'</(strong|b)>', caseSensitive: false), '**');
  s = s.replaceAll(RegExp(r'<(em|i)\b[^>]*>', caseSensitive: false), '*');
  s = s.replaceAll(RegExp(r'</(em|i)>', caseSensitive: false), '*');
  s = s.replaceAll(
      RegExp(r'<(del|s|strike)\b[^>]*>', caseSensitive: false), '~~');
  s = s.replaceAll(
      RegExp(r'</(del|s|strike)>', caseSensitive: false), '~~');
  s = s.replaceAll(RegExp(r'<code\b[^>]*>', caseSensitive: false), '`');
  s = s.replaceAll(RegExp(r'</code>', caseSensitive: false), '`');
  return s;
}

String _plainText(String html) {
  final String stripped = html.replaceAll(RegExp(r'<[^>]+>'), '');
  return _decodeEntities(stripped).replaceAll(RegExp(r'\s+'), ' ').trim();
}

String? _attribute(String tag, String name) {
  final Match? match = RegExp(
    '$name\\s*=\\s*["\']([^"\']*)["\']',
    caseSensitive: false,
  ).firstMatch(tag);
  return match?.group(1);
}

String _decodeEntities(String text) {
  var s = text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'");
  s = s.replaceAllMapped(
    RegExp(r'&#(x?[0-9a-fA-F]+);'),
    (Match m) {
      final String raw = m.group(1)!;
      final int? code = raw.startsWith('x') || raw.startsWith('X')
          ? int.tryParse(raw.substring(1), radix: 16)
          : int.tryParse(raw);
      if (code == null || code <= 0) {
        return m.group(0)!;
      }
      return String.fromCharCode(code);
    },
  );
  // &amp; 最后解，避免 `&amp;lt;` 被二次解码成 `<`。
  return s.replaceAll('&amp;', '&');
}
