import 'dart:math' as math;

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
  // 规则当成 HTML 标签吃掉（实测 `a < b` 会变成 `a`）。语言标记从
  // `<pre class="language-dart">` / `<code class="lang-dart">` 里取，
  // 语雀、GitHub、Notion 复制都带这个信息，丢了会变成无语言代码块。
  final List<({String language, String code})> codeBlocks =
      <({String language, String code})>[];
  s = s.replaceAllMapped(
    RegExp(r'<pre[^>]*>([\s\S]*?)</pre>', caseSensitive: false),
    (Match m) {
      final String code = _decodeEntities(
        m.group(1)!.replaceAll(RegExp(r'<[^>]+>'), ''),
      ).trimRight();
      final String token = '\u0000CODE${codeBlocks.length}\u0000';
      codeBlocks.add((language: _codeLanguage(m.group(0)!), code: code));
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

  // 表格：先整块取出转成 GFM 管道表格。若留在原地，`<td>` 会被后面的
  // 规则压成「| 单元格 | 」的一行文字（旧版就是这样，行列结构全丢）。
  final List<String> tables = <String>[];
  s = s.replaceAllMapped(
    RegExp(r'<table\b[\s\S]*?</table>', caseSensitive: false),
    (Match m) {
      final String table = _htmlTableToMarkdown(m.group(0)!);
      if (table.isEmpty) {
        return '';
      }
      final String token = '\u0000TABLE${tables.length}\u0000';
      tables.add(table);
      return '\n\n$token\n\n';
    },
  );

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
    final String language = codeBlocks[i].language;
    s = s.replaceAll(
      '\u0000CODE$i\u0000',
      '```$language\n${codeBlocks[i].code}\n```',
    );
  }
  // 还原表格占位符：表格前后留空行，GFM 表格块需要与相邻段落分开。
  for (int i = 0; i < tables.length; i++) {
    s = s.replaceAll('\u0000TABLE$i\u0000', '\n${tables[i]}\n');
  }
  return s.trim();
}

/// `<table>` → GFM 管道表格。
///
/// 语雀、网页、Word 复制表格都会带 `<table>`。这里保留行列结构：首行升为
/// 表头（GFM 必须有表头），`colspan` 用空单元格补齐，`rowspan` 在管道语法
/// 里无法表达，直接忽略（内容仍留在被合并的那一行）。单元格内的段落、
/// 列表、换行压成一行；粗体 / 链接等行内样式照常保留。
String _htmlTableToMarkdown(String tableHtml) {
  final List<String> rowHtmls = <String>[
    for (final Match m in RegExp(
      r'<tr\b[^>]*>([\s\S]*?)</tr>',
      caseSensitive: false,
    ).allMatches(tableHtml))
      m.group(1)!,
  ];
  if (rowHtmls.isEmpty) {
    return '';
  }

  final List<List<String>> rows = <List<String>>[];
  List<String?>? headerAligns;
  for (final String rowHtml in rowHtmls) {
    final List<String> cells = <String>[];
    final List<String?> rowAligns = <String?>[];
    for (final Match m in RegExp(
      r'<(td|th)\b([^>]*)>([\s\S]*?)</\1>',
      caseSensitive: false,
    ).allMatches(rowHtml)) {
      final String attrs = m.group(2)!;
      cells.add(_htmlTableCellText(m.group(3)!));
      rowAligns.add(_tableCellAlign(attrs));
      // colspan 用空单元格占位，保证各行宽度一致（上限 32，防异常值）。
      final int colspan =
          int.tryParse(
            RegExp(
                  r'''colspan\s*=\s*["']?(\d+)''',
                  caseSensitive: false,
                ).firstMatch(attrs)?.group(1) ??
                '',
          ) ??
          1;
      for (var i = 1; i < math.min(colspan, 32); i++) {
        cells.add('');
        rowAligns.add(null);
      }
    }
    if (cells.isEmpty) {
      continue;
    }
    rows.add(cells);
    headerAligns ??= rowAligns;
  }
  if (rows.isEmpty) {
    return '';
  }

  final int columns =
      rows.map((List<String> row) => row.length).reduce(math.max);
  String rowLine(List<String> cells) {
    final List<String> padded = <String>[
      for (var i = 0; i < columns; i++) i < cells.length ? cells[i] : '',
    ];
    return '| ${padded.join(' | ')} |';
  }

  final List<String?> aligns = headerAligns ?? const <String?>[];
  final StringBuffer buffer = StringBuffer(rowLine(rows.first));
  buffer.write('\n| ');
  buffer.write(<String>[
    for (var i = 0; i < columns; i++)
      _tableSeparator(i < aligns.length ? aligns[i] : null),
  ].join(' | '));
  buffer.write(' |');
  for (var r = 1; r < rows.length; r++) {
    buffer.write('\n${rowLine(rows[r])}');
  }
  return buffer.toString();
}

/// 单元格文本：块级边界与换行压成空格，剥标签、保留行内样式、转义 `|`。
String _htmlTableCellText(String html) {
  final String cell = html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ')
      .replaceAll(
        RegExp(
          r'</?(p|div|li|ul|ol|h[1-6])\b[^>]*>',
          caseSensitive: false,
        ),
        ' ',
      );
  return _decodeEntities(
    _inline(cell).replaceAll(RegExp(r'<[^>]+>'), ''),
  ).replaceAll(RegExp(r'\s+'), ' ').replaceAll('|', r'\|').trim();
}

/// 单元格对齐：兼容 `align="center"` 与 `style="text-align:center"`。
String? _tableCellAlign(String attrs) {
  final Match? direct = RegExp(
    r'''align\s*=\s*["']?\s*(left|center|right)''',
    caseSensitive: false,
  ).firstMatch(attrs);
  if (direct != null) {
    return direct.group(1)!.toLowerCase();
  }
  final Match? style = RegExp(
    r'text-align\s*:\s*(left|center|right)',
    caseSensitive: false,
  ).firstMatch(attrs);
  return style?.group(1)?.toLowerCase();
}

String _tableSeparator(String? align) {
  return switch (align) {
    'center' => ':---:',
    'right' => '---:',
    'left' => ':---',
    _ => '---',
  };
}

/// 列表：`<ul>` 用 `- `，`<ol>` 用 `1. `，嵌套层级用两空格缩进。
///
/// 之前是全局替换 `<li>`，嵌套列表会被压成同级、且每项之间多出空行
/// （语雀复制出来的正文几乎都是 `<ul><li><p>…` 结构）。这里改成递归：
/// 先按同类型标签配对找出整个列表，再按「顶层 li」切分，子列表递归处理。
/// 待办列表（`<input type="checkbox">`）转成 `- [ ]` / `- [x]`。
String _convertLists(String html) {
  final String converted = _convertListsAtDepth(html, 0);
  // 兜底：不在列表里的 <li>（畸形 HTML）退回为无序项。
  return converted
      .replaceAll(RegExp(r'<li\b[^>]*>', caseSensitive: false), '\n- ')
      .replaceAll(RegExp(r'</li>', caseSensitive: false), '');
}

String _convertListsAtDepth(String html, int depth) {
  final StringBuffer out = StringBuffer();
  var cursor = 0;
  final RegExp open = RegExp(r'<(ul|ol)\b([^>]*)>', caseSensitive: false);
  while (true) {
    final String rest = html.substring(cursor);
    final Match? match = open.firstMatch(rest);
    if (match == null) {
      out.write(rest);
      break;
    }
    final int start = cursor + match.start;
    out.write(html.substring(cursor, start));
    final String tag = match.group(1)!.toLowerCase();
    final int closeStart = _matchingListClose(html, start);
    if (closeStart < 0) {
      out.write(html.substring(start));
      break;
    }
    final int innerStart = start + match.group(0)!.length;
    final String inner = html.substring(innerStart, closeStart);
    out.write('\n${_listToMarkdown(inner, tag, match.group(2) ?? '', depth)}\n');
    cursor = closeStart + '</$tag>'.length;
  }
  return out.toString();
}

/// 从 [openStart] 处的 `<ul>`/`<ol>` 找到配对闭合标签的起始下标。
///
/// 按「所有列表标签」计数（ul 里可能嵌 ol），返回 -1 表示没有闭合。
int _matchingListClose(String html, int openStart) {
  final RegExp token = RegExp(r'</?(?:ul|ol)\b[^>]*>', caseSensitive: false);
  var depth = 0;
  for (final Match m in token.allMatches(html.substring(openStart))) {
    if (m.group(0)!.startsWith('</')) {
      depth--;
      if (depth == 0) {
        return openStart + m.start;
      }
    } else {
      depth++;
    }
  }
  return -1;
}

/// 切出列表的「顶层 li」内容（嵌套列表内部的 li 不算）。
List<String> _topLevelListItems(String inner) {
  final RegExp token = RegExp(
    r'<(?:ul|ol)\b[^>]*>|</(?:ul|ol)>|<li\b[^>]*>|</li>',
    caseSensitive: false,
  );
  final List<String> items = <String>[];
  var listDepth = 0;
  var itemStart = -1;
  for (final Match m in token.allMatches(inner)) {
    final String t = m.group(0)!;
    if (t.startsWith('</')) {
      if (t.startsWith('</li')) {
        if (listDepth == 0 && itemStart >= 0) {
          items.add(inner.substring(itemStart, m.start));
          itemStart = -1;
        }
      } else {
        listDepth--;
      }
    } else if (t.startsWith('<li')) {
      if (listDepth == 0) {
        itemStart = m.end;
      }
    } else {
      listDepth++;
    }
  }
  // 容错：没有闭合的最后一个 li 也保留内容。
  if (listDepth == 0 && itemStart >= 0 && itemStart <= inner.length) {
    items.add(inner.substring(itemStart));
  }
  return items;
}

String _listToMarkdown(String inner, String tag, String attrs, int depth) {
  final List<String> items = _topLevelListItems(inner);
  if (items.isEmpty) {
    return '';
  }
  final bool ordered = tag == 'ol';
  final int startNumber = int.tryParse(
        RegExp(r'''start\s*=\s*["']?(\d+)''', caseSensitive: false)
                .firstMatch(attrs)
                ?.group(1) ??
            '',
      ) ??
      1;
  final String indent = '  ' * depth;
  final List<String> lines = <String>[];
  var number = startNumber;

  for (final String item in items) {
    // 嵌套列表从条目内容里摘出来，递归展开到下一层。
    final RegExp nestedOpen =
        RegExp(r'<(ul|ol)\b[^>]*>', caseSensitive: false);
    final Match? nested = nestedOpen.firstMatch(item);
    final String content =
        nested == null ? item : item.substring(0, nested.start);
    final String nestedHtml =
        nested == null ? '' : item.substring(nested.start);

    final bool isTask = RegExp(
      r'''<input\b[^>]*type\s*=\s*["']?checkbox''',
      caseSensitive: false,
    ).hasMatch(content);
    final bool checked = RegExp(
      r'''<input\b[^>]*\bchecked\b''',
      caseSensitive: false,
    ).hasMatch(content);

    final String text = _listItemText(content);
    final String marker;
    if (isTask) {
      marker = checked ? '- [x] ' : '- [ ] ';
    } else if (ordered) {
      marker = '$number. ';
      number++;
    } else {
      marker = '- ';
    }
    lines.add('$indent$marker$text');
    if (nestedHtml.isNotEmpty) {
      // 只去掉首尾的空白行，不能 trim —— 子列表的行首缩进就是层级本身。
      final List<String> childLines =
          _convertListsAtDepth(nestedHtml, depth + 1).split('\n');
      while (childLines.isNotEmpty && childLines.first.trim().isEmpty) {
        childLines.removeAt(0);
      }
      while (childLines.isNotEmpty && childLines.last.trim().isEmpty) {
        childLines.removeLast();
      }
      if (childLines.isNotEmpty) {
        lines.add(childLines.join('\n'));
      }
    }
  }
  return lines.join('\n');
}

/// 列表项文本：块级标签压成空格、保留行内样式，勾选框本身不产生文字。
String _listItemText(String html) {
  final String noCheckbox = html.replaceAll(
    RegExp(r'<input\b[^>]*>', caseSensitive: false),
    '',
  );
  final String noBlocks = noCheckbox
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ')
      .replaceAll(
        RegExp(
          r'</?(p|div|section|article|h[1-6]|li|ul|ol)\b[^>]*>',
          caseSensitive: false,
        ),
        ' ',
      );
  return _decodeEntities(_inline(noBlocks).replaceAll(RegExp(r'<[^>]+>'), ''))
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// 代码块语言：`language-dart` / `lang-dart` / `<pre class="dart">` 均兼容。
String _codeLanguage(String preHtml) {
  final Match? classMatch = RegExp(
    r'''class\s*=\s*["']([^"']*)["']''',
    caseSensitive: false,
  ).firstMatch(preHtml);
  final String classes = classMatch?.group(1) ?? '';
  final Match? lang = RegExp(
    r'(?:language|lang)-([A-Za-z0-9_+#.-]+)',
    caseSensitive: false,
  ).firstMatch(classes);
  return lang?.group(1) ?? '';
}

/// 行内样式与链接。
String _inline(String html) {
  var s = html;

  // 链接：保留文字、href 与 title；空文字时直接给出 URL。
  s = s.replaceAllMapped(
    RegExp(r'<a\b([^>]*)>([\s\S]*?)</a>', caseSensitive: false),
    (Match m) {
      final String attrs = m.group(1)!;
      final String href = (_attribute(attrs, 'href') ?? '').trim();
      final String title = (_attribute(attrs, 'title') ?? '').trim();
      final String label = _plainText(m.group(2)!);
      if (href.isEmpty) {
        return label;
      }
      if (label.isEmpty) {
        return href;
      }
      // 小记的链接支持 title：`[文字](url "标题")`。
      return title.isEmpty
          ? '[$label]($href)'
          : '[${label.replaceAll('"', r'\"')}]($href "${title.replaceAll('"', r'\"')}")';
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
  // 高亮：网页里的 `<mark>` 对应小记的 `==…==`。
  s = s.replaceAll(RegExp(r'<mark\b[^>]*>', caseSensitive: false), '==');
  s = s.replaceAll(RegExp(r'</mark>', caseSensitive: false), '==');
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
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'");
  // 常见命名实体：网页 / 语雀复制过来的正文里 `&mdash;`、`&hellip;`、
  // `&rsquo;` 很常见，不解析会在正文里原样显示成 `&mdash;`
  // （用户反馈「特殊符号显示不正常」）。
  s = s.replaceAllMapped(
    RegExp(r'&([a-zA-Z][a-zA-Z0-9]{1,31});'),
    (Match m) => _namedHtmlEntities[m.group(1)] ?? m.group(0)!,
  );
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

/// 常见 HTML 命名实体 → 字符。
///
/// 只收「正文里会真的出现」的标点与符号；未收录的保持原样，不猜。
const Map<String, String> _namedHtmlEntities = <String, String>{
  'nbsp': ' ',
  'ensp': '\u2002',
  'emsp': '\u2003',
  'thinsp': '\u2009',
  'zwnj': '\u200C',
  'zwj': '\u200D',
  'mdash': '—',
  'ndash': '–',
  'hellip': '…',
  'middot': '·',
  'bull': '•',
  'lsquo': '‘',
  'rsquo': '’',
  'ldquo': '“',
  'rdquo': '”',
  'laquo': '«',
  'raquo': '»',
  'lsaquo': '‹',
  'rsaquo': '›',
  'copy': '©',
  'reg': '®',
  'trade': '™',
  'sect': '§',
  'para': '¶',
  'deg': '°',
  'plusmn': '±',
  'times': '×',
  'divide': '÷',
  'minus': '−',
  'sup2': '²',
  'sup3': '³',
  'frac12': '½',
  'frac14': '¼',
  'frac34': '¾',
  'euro': '€',
  'pound': '£',
  'yen': '¥',
  'cent': '¢',
  'larr': '←',
  'rarr': '→',
  'uarr': '↑',
  'darr': '↓',
  'harr': '↔',
  'dagger': '†',
  'Dagger': '‡',
  'prime': '′',
  'Prime': '″',
  'check': '✓',
  'cross': '✗',
  'star': '★',
  'hearts': '♥',
};
