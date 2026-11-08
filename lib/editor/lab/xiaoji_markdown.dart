import 'package:flutter/foundation.dart' show debugPrint;
import 'package:super_editor/super_editor.dart';

/// 任务行：`- [ ]` / `- [x]`（含 `*`/`+` 与缩进）。
final RegExp _taskLinePattern = RegExp(r'^\s*[-*+]\s\[[ xX]\]\s');

/// 普通列表行（含任务行）。
final RegExp _listLinePattern = RegExp(r'^\s*([-*+]\s|\d+[.)]\s)');

/// 解析前规范化。
///
/// super_editor 的 markdown 解析器有一个实测缺陷：任务行若与前面的列表
/// 用空行隔开（松散列表），checkbox 的勾选状态会丢失、文本带前导换行。
/// 这里把「普通列表行 ↔ 任务行」之间的空行删掉（只在解析副本上做，
/// 不改原文件）——其余空行原样保留，普通列表之间的分段不受影响。
String normalizeMarkdownForKernel(String md) {
  final lines = md.split('\n');
  final out = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty && out.isNotEmpty && i < lines.length - 1) {
      final prev = out.last;
      var next = '';
      for (var j = i + 1; j < lines.length; j++) {
        if (lines[j].trim().isNotEmpty) {
          next = lines[j];
          break;
        }
      }
      final crossesTask = (_listLinePattern.hasMatch(prev) &&
              _taskLinePattern.hasMatch(next)) ||
          (_taskLinePattern.hasMatch(prev) && _listLinePattern.hasMatch(next));
      if (crossesTask) {
        continue;
      }
    }
    out.add(line);
  }
  return out.join('\n');
}

/// `==高亮==` 的行内属性。
///
/// super_editor 内核只认粗体/斜体/删除线/行内码/链接，高亮是扩展语法：
/// 解析后我们把标记字符摘掉、把区间打上这个自定义属性，
/// 渲染端（编辑器 inlineTextStyler / 首页摘要）再按属性上色。
const Attribution highlightAttribution = NamedAttribution('highlight');

/// `==高亮==`：等号对之间不能有等号或换行（与主流实现一致）。
final RegExp _highlightPattern = RegExp(r'==([^=\n]+)==');

/// 把 `==...==` 换成 [highlightAttribution]，标记字符从文本里删除。
///
/// 返回 null 表示这段文本没有高亮标记。已有的行内样式（粗体/链接等）
/// 会按「删除标记后的新位置」重映射，不会因为位置变化而错位。
AttributedText? _highlightToAttribution(AttributedText source) {
  final String plain = source.toPlainText();
  if (!plain.contains('==')) {
    return null;
  }
  final List<RegExpMatch> matches = _highlightPattern.allMatches(plain).toList();
  if (matches.isEmpty) {
    return null;
  }

  final StringBuffer buffer = StringBuffer();
  final List<({int start, int end})> highlightRanges = <({int start, int end})>[];
  // 被删掉的 `==` 标记（每个标记 2 个字符），用于把旧下标映射到新文本。
  final List<({int oldStart, int oldEnd})> removed = <({int oldStart, int oldEnd})>[];
  var oldCursor = 0;
  var newLength = 0;
  for (final RegExpMatch match in matches) {
    final String before = plain.substring(oldCursor, match.start);
    buffer.write(before);
    newLength += before.length;

    final String inner = match.group(1)!;
    final int start = newLength;
    buffer.write(inner);
    newLength += inner.length;
    highlightRanges.add((start: start, end: newLength - 1));

    removed.add((oldStart: match.start, oldEnd: match.start + 1));
    removed.add((oldStart: match.end - 2, oldEnd: match.end - 1));
    oldCursor = match.end;
  }
  buffer.write(plain.substring(oldCursor));

  final AttributedText result = AttributedText(buffer.toString());

  int mapIndex(int oldIndex) {
    var shift = 0;
    for (final ({int oldStart, int oldEnd}) range in removed) {
      if (oldIndex > range.oldEnd) {
        shift += range.oldEnd - range.oldStart + 1;
        continue;
      }
      if (oldIndex >= range.oldStart) {
        // 落在被删掉的标记里（如 `==重点==` 整体是粗体时，粗体区间从
        // 第一个 `=` 开始）：夹到标记后的第一个字符，样式不丢。
        return range.oldStart - shift;
      }
      // removed 按位置升序，后面的都比 oldIndex 大。
      break;
    }
    return oldIndex - shift;
  }

  if (plain.isNotEmpty) {
    final spans = source.spans.getAttributionSpansInRange(
      attributionFilter: (Attribution _) => true,
      start: 0,
      end: plain.length - 1,
    );
    for (final span in spans) {
      final int start = mapIndex(span.start);
      final int end = mapIndex(span.end);
      if (start < 0 || end < start || start >= result.length) {
        continue;
      }
      result.addAttribution(
        span.attribution,
        SpanRange(start, end >= result.length ? result.length - 1 : end),
      );
    }
  }
  for (final ({int start, int end}) range in highlightRanges) {
    if (range.end < range.start || range.start >= result.length) {
      continue;
    }
    result.addAttribution(
      highlightAttribution,
      SpanRange(range.start, range.end),
    );
  }
  return result;
}

/// 对所有文本节点应用 `==高亮==`（代码块内部保持原样）。
void _applyHighlights(MutableDocument document) {
  for (var i = 0; i < document.nodeCount; i++) {
    final DocumentNode? node = document.getNodeAt(i);
    if (node == null) {
      continue;
    }
    if (node is TableBlockNode) {
      // 表格单元格也要支持：重建整张表的单元格网格。
      List<List<TextNode>>? cells;
      for (var r = 0; r < node.rowCount; r++) {
        for (var c = 0; c < node.columnCount; c++) {
          final TextNode cell = node.getCell(rowIndex: r, columnIndex: c);
          final AttributedText? text = _highlightToAttribution(cell.text);
          if (text == null) {
            continue;
          }
          cells ??= <List<TextNode>>[
            for (var row = 0; row < node.rowCount; row++)
              List<TextNode>.from(node.getRow(row)),
          ];
          cells[r][c] = cell.copyTextNodeWith(text: text);
        }
      }
      if (cells != null) {
        document.replaceNodeById(
          node.id,
          TableBlockNode(
            id: node.id,
            cells: cells,
            metadata: node.copyMetadata(),
          ),
        );
      }
      continue;
    }
    if (node is! TextNode) {
      continue;
    }
    // 代码块里的 == 是代码，不是语法。
    if (node.getMetadataValue(NodeMetadata.blockType) == codeAttribution) {
      continue;
    }
    final AttributedText? text = _highlightToAttribution(node.text);
    if (text != null) {
      document.replaceNodeById(node.id, node.copyTextNodeWith(text: text));
    }
  }
}

/// 解析前的块级语法修补。
///
/// 内核解析器有几处与 CommonMark 的偏差，必须在解析前校正：
///  - **setext 标题**（`标题` 下一行 `===` / `---`）不会被识别，`===` / `---`
///    会变成正文或分隔线 → 转成 ATX（`# ` / `## `）；
///  - **嵌套引用**（`> > 文本`）会把两层文本直接拼在一起（「外层内层」）
///    → 拍平成单层，至少保住换行；
///  - **缩进的列表/待办**会被并进上一项文本（子任务标记直接丢失）
///    → 解析时先去掉缩进，解析后再把层级写回节点。
({String markdown, List<int> listIndents}) _normalizeBlockSpecials(String md) {
  final List<String> lines = md.split('\n');
  final List<String> out = <String>[];
  final List<int> indents = <int>[];
  var insideFence = false;
  for (final String line in lines) {
    final String trimmedLeft = line.trimLeft();
    if (trimmedLeft.startsWith('```') || trimmedLeft.startsWith('~~~')) {
      insideFence = !insideFence;
      out.add(line);
      continue;
    }
    if (insideFence) {
      out.add(line);
      continue;
    }

    // setext 标题：只能跟在普通段落行后面。
    final RegExpMatch? setext =
        RegExp(r'^\s{0,3}(=+|-+)\s*$').firstMatch(line);
    if (setext != null && out.isNotEmpty && _isPlainParagraphLine(out.last)) {
      final bool h1 = setext.group(1)!.startsWith('=');
      out[out.length - 1] = '${h1 ? '#' : '##'} ${out.last.trim()}';
      continue;
    }

    // 嵌套引用：保留文字与换行，层级压平（模型只支持一层）。
    final RegExpMatch? quote =
        RegExp(r'^(\s*)(?:>\s*){2,}(.*)$').firstMatch(line);
    if (quote != null) {
      out.add('${quote.group(1)}> ${quote.group(2)!.trimLeft()}');
      continue;
    }

    // 列表/待办：记录层级，解析时按顶层处理。
    final RegExpMatch? list =
        RegExp(r'^(\s*)((?:[-*+]|\d+[.)])\s+.*)$').firstMatch(line);
    if (list != null) {
      final int width = _indentWidth(list.group(1)!);
      indents.add(width ~/ 2);
      out.add(width > 0 ? list.group(2)! : line);
      continue;
    }
    out.add(line);
  }
  return (markdown: out.join('\n'), listIndents: indents);
}

/// 这一行是不是「可以被 setext 下划线升级」的普通段落行。
bool _isPlainParagraphLine(String line) {
  final String t = line.trimLeft();
  if (t.isEmpty || t == _blankParagraphSentinel) {
    return false;
  }
  if (t.startsWith('#') ||
      t.startsWith('>') ||
      t.startsWith('|') ||
      t.startsWith('```') ||
      t.startsWith('~~~')) {
    return false;
  }
  return !RegExp(r'^([-*+]|\d+[.)])\s').hasMatch(t);
}

/// 缩进宽度：空格 1，Tab 按 4 计。
int _indentWidth(String indent) {
  var width = 0;
  for (final int unit in indent.codeUnits) {
    width += unit == 9 ? 4 : 1;
  }
  return width;
}

/// 把解析前记录的列表层级写回节点。
///
/// 节点数量对不上（解析器吞掉了某行）时整体放弃，避免把层级错位到
/// 别的条目上 —— 宁可层级不准，也不能把内容挂到错误的父项。
void _restoreListIndents(MutableDocument document, List<int> indents) {
  if (indents.isEmpty) {
    return;
  }
  final List<DocumentNode> items = <DocumentNode>[
    for (var i = 0; i < document.nodeCount; i++)
      if (document.getNodeAt(i) case final DocumentNode node
          when node is ListItemNode || node is TaskNode)
        node,
  ];
  if (items.length != indents.length) {
    debugPrint(
      '[markdown] 列表层级记录数不一致：nodes=${items.length} '
      'lines=${indents.length}，跳过层级还原',
    );
    return;
  }
  for (var i = 0; i < items.length; i++) {
    final DocumentNode node = items[i];
    final int depth = indents[i];
    if (node is TaskNode) {
      if (node.indent != depth) {
        document.replaceNodeById(node.id, node.copyTaskWith(indent: depth));
      }
    } else if (node is ListItemNode) {
      if (node.indent != depth) {
        document.replaceNodeById(node.id, node.copyListItemWith(indent: depth));
      }
    }
  }
}

/// 链接 title（`[文字](url "标题")`）的承载者。
///
/// 内核的 [LinkAttribution] 只有 URI，没有 title；这里用子类挂上 title，
/// 序列化时再写回。子类仍然是一个 LinkAttribution，打开链接、点击判定、
/// 复制粘贴都不受影响。
class XiaojiLinkAttribution extends LinkAttribution {
  const XiaojiLinkAttribution(super.plainTextUri, [super.uri, this.title = '']);

  /// `[文字](url "标题")` 里的标题，空串表示没有标题。
  final String title;
}

/// 链接 title 的提取结果。
///
/// 解析前先把 title 从 `[文字](url "标题")` 里摘出来（内核不认），
/// 解析后按 URL 顺序回填到对应的 [LinkAttribution] 上。
final RegExp _linkWithTitlePattern = RegExp(
  r'''!?\[([^\]\n]*)\]\(\s*([^)\s]+)\s+(?:"([^"]*)"|'([^']*)'|\(([^)]*)\))\s*\)''',
);

({String markdown, Map<String, List<String>> titles}) _extractLinkTitles(
  String md,
) {
  final Map<String, List<String>> titles = <String, List<String>>{};
  final String stripped = md.replaceAllMapped(_linkWithTitlePattern, (Match m) {
    final String url = m.group(2)!;
    final String title = m.group(3) ?? m.group(4) ?? m.group(5) ?? '';
    titles.putIfAbsent(url, () => <String>[]).add(title);
    return '${m.group(0)!.startsWith('!') ? '!' : ''}[${m.group(1)}]($url)';
  });
  return (markdown: stripped, titles: titles);
}

/// 把 title 回填到链接属性上（普通段落与表格单元格都处理）。
void _restoreLinkTitles(
  MutableDocument document,
  Map<String, List<String>> titles,
) {
  if (titles.isEmpty) {
    return;
  }
  for (var i = 0; i < document.nodeCount; i++) {
    final DocumentNode? node = document.getNodeAt(i);
    if (node == null) {
      continue;
    }
    if (node is TableBlockNode) {
      List<List<TextNode>>? cells;
      for (var r = 0; r < node.rowCount; r++) {
        for (var c = 0; c < node.columnCount; c++) {
          final TextNode cell = node.getCell(rowIndex: r, columnIndex: c);
          final AttributedText? text = _linkTitleText(cell.text, titles);
          if (text == null) {
            continue;
          }
          cells ??= <List<TextNode>>[
            for (var row = 0; row < node.rowCount; row++)
              List<TextNode>.from(node.getRow(row)),
          ];
          cells[r][c] = cell.copyTextNodeWith(text: text);
        }
      }
      if (cells != null) {
        document.replaceNodeById(
          node.id,
          TableBlockNode(
            id: node.id,
            cells: cells,
            metadata: node.copyMetadata(),
          ),
        );
      }
      continue;
    }
    if (node is! TextNode) {
      continue;
    }
    final AttributedText? text = _linkTitleText(node.text, titles);
    if (text != null) {
      document.replaceNodeById(node.id, node.copyTextNodeWith(text: text));
    }
  }
}

/// 把一段文本里的链接换成带 title 的子类；没有可回填的 title 时返回 null。
AttributedText? _linkTitleText(
  AttributedText source,
  Map<String, List<String>> titles,
) {
  AttributedText? result;
  var i = 0;
  while (i < source.length) {
    final LinkAttribution? link = source.spans
        .getAllAttributionsAt(i)
        .whereType<LinkAttribution>()
        .firstOrNull;
    if (link == null) {
      i++;
      continue;
    }
    final SpanRange range = source.spans.getAttributedRange({link}, i);
    final List<String>? queue = titles[link.plainTextUri];
    final String title =
        queue != null && queue.isNotEmpty ? queue.removeAt(0) : '';
    if (title.isNotEmpty) {
      result ??= source.copyText(0);
      result.removeAttribution(link, range);
      result.addAttribution(
        XiaojiLinkAttribution(link.plainTextUri, link.uri, title),
        range,
      );
    }
    i = range.end + 1;
  }
  return result;
}

/// 有序列表起始编号的 metadata key。
///
/// 内核模型里有序项只有「同层第几个」，没有起始编号（`5.` 会被写成 `1.`）。
/// 解析前按行记录源编号，解析后把每个 run 的起始编号挂到节点上；
/// 渲染与序列化都按「起始编号 + 层内序号 - 1」计算。
const String kOrderedStartMetadata = 'orderedStart';

/// 解析前依序收集有序列表行的编号（含缩进行，跳过代码块）。
List<int> _collectOrderedNumbers(String markdown) {
  final List<int> numbers = <int>[];
  var insideFence = false;
  for (final String line in markdown.split('\n')) {
    final String t = line.trimLeft();
    if (t.startsWith('```') || t.startsWith('~~~')) {
      insideFence = !insideFence;
      continue;
    }
    if (insideFence) {
      continue;
    }
    final RegExpMatch? m = RegExp(r'^(\d+)[.)]\s+').firstMatch(t);
    if (m != null) {
      numbers.add(int.parse(m.group(1)!));
    }
  }
  return numbers;
}

/// 有序项的「层内序号」与「run 起始编号」。
///
/// 序号规则与内核一致：向上找同层连续的有序项；遇到同层无序项或非列表块
/// 就断开。起始编号取该 run 第一项上记录的 metadata。
({int ordinal, int start})? orderedListItemNumber(
  Document document,
  ListItemNode item,
) {
  if (item.type != ListItemType.ordered) {
    return null;
  }
  var ordinal = 1;
  ListItemNode first = item;
  DocumentNode? above = document.getNodeBeforeById(item.id);
  while (above is ListItemNode && above.indent >= item.indent) {
    if (above.indent == item.indent) {
      if (above.type != ListItemType.ordered) {
        break;
      }
      ordinal++;
      first = above;
    }
    above = document.getNodeBeforeById(above.id);
  }
  final int start =
      (first.getMetadataValue(kOrderedStartMetadata) as int?) ?? 1;
  return (ordinal: ordinal, start: start);
}

/// 把源编号按 run 写回节点（0 基 run 的首项保存起始编号）。
void _restoreOrderedStarts(MutableDocument document, List<int> numbers) {
  if (numbers.isEmpty) {
    return;
  }
  final List<ListItemNode> items = <ListItemNode>[
    for (var i = 0; i < document.nodeCount; i++)
      if (document.getNodeAt(i) case final ListItemNode node
          when node.type == ListItemType.ordered)
        node,
  ];
  if (items.length != numbers.length) {
    debugPrint(
      '[markdown] 有序列表编号记录数不一致：nodes=${items.length} '
      'lines=${numbers.length}，跳过起始编号还原',
    );
    return;
  }
  final Map<String, int> sourceById = <String, int>{
    for (var i = 0; i < items.length; i++) items[i].id: numbers[i],
  };
  for (final ListItemNode item in items) {
    // 找这个 run 的第一项（与 orderedListItemNumber 同规则）。
    ListItemNode first = item;
    DocumentNode? above = document.getNodeBeforeById(item.id);
    while (above is ListItemNode && above.indent >= item.indent) {
      if (above.indent == item.indent) {
        if (above.type != ListItemType.ordered) {
          break;
        }
        first = above;
      }
      above = document.getNodeBeforeById(above.id);
    }
    final int start = sourceById[first.id] ?? 1;
    if (start > 1) {
      document.replaceNodeById(
        item.id,
        item.copyListItemWith(metadata: <String, dynamic>{
          ...item.metadata,
          kOrderedStartMetadata: start,
        }),
      );
    }
  }
}

/// 代码块语言标记的 metadata key。
///
/// super_editor 的模型只存代码文本，不记住围栏后面的语言（` ```dart `
/// 解析后只剩代码内容）。这里在解析后把语言按顺序挂到节点 metadata 上，
/// 序列化时再写回，保证「复制一段带语言的代码 → 保存 → 重开」不丢信息。
const String kCodeLanguageMetadata = 'codeLanguage';

/// 依序收集围栏代码块的语言标记（与文档里代码块的出现顺序一致）。
///
/// 同时支持 ``` 与 ~~~ 两种围栏；只有「同字符、长度不小于开启围栏、
/// 后面没有内容」的行才算闭合，避免把代码里的 ``` 当成结束。
List<String> _collectCodeFenceLanguages(String markdown) {
  final List<String> languages = <String>[];
  String fenceChar = '';
  int fenceLength = 0;
  for (final String line in markdown.split('\n')) {
    final RegExpMatch? match =
        RegExp(r'^([`~]{3,})([^`~]*)$').firstMatch(line.trimLeft());
    if (match == null) {
      continue;
    }
    final String marker = match.group(1)!;
    final String info = match.group(2)!.trim();
    if (fenceLength == 0) {
      fenceChar = marker[0];
      fenceLength = marker.length;
      languages.add(info);
    } else if (marker[0] == fenceChar &&
        marker.length >= fenceLength &&
        info.isEmpty) {
      fenceChar = '';
      fenceLength = 0;
    }
  }
  return languages;
}

/// 把语言标记按顺序写回代码块节点。
void _restoreCodeFenceLanguages(
  MutableDocument document,
  List<String> languages,
) {
  if (languages.isEmpty) {
    return;
  }
  var index = 0;
  for (var i = 0; i < document.nodeCount; i++) {
    final DocumentNode? node = document.getNodeAt(i);
    if (node == null ||
        node is! ParagraphNode ||
        node.getMetadataValue(NodeMetadata.blockType) != codeAttribution) {
      continue;
    }
    if (index >= languages.length) {
      return;
    }
    final String language = languages[index++];
    if (language.isEmpty) {
      continue;
    }
    document.replaceNodeById(
      node.id,
      node.copyWithAddedMetadata(<String, dynamic>{
        kCodeLanguageMetadata: language,
      }),
    );
  }
}

/// 解析入口：规范化 + super_editor 解析 + 空行/任务行/附件行拆分。
/// 编辑页与测试统一走这里。
MutableDocument deserializeXiaojiMarkdown(String md) {
  final String prepared = _isolateImageLines(_protectBlankLines(md));
  // 块级修补（setext 标题 / 嵌套引用 / 列表缩进）要在解析前完成。
  final ({String markdown, List<int> listIndents}) specials =
      _normalizeBlockSpecials(prepared);
  // 链接 title 内核不认：先摘出来，解析后再回填到链接属性上。
  final ({String markdown, Map<String, List<String>> titles}) links =
      _extractLinkTitles(specials.markdown);
  // 语言标记 / 有序编号要先按源码顺序收集：解析后的文档里没有这些信息。
  final List<String> codeLanguages =
      _collectCodeFenceLanguages(links.markdown);
  final List<int> orderedNumbers = _collectOrderedNumbers(links.markdown);
  final document = deserializeMarkdownToDocument(
    normalizeMarkdownForKernel(links.markdown),
  );
  _restoreListIndents(document, specials.listIndents);
  _restoreOrderedStarts(document, orderedNumbers);
  _restoreCodeFenceLanguages(document, codeLanguages);
  _applyHighlights(document);
  _restoreLinkTitles(document, links.titles);
  _splitMultilineTasks(document);
  _splitAttachmentLines(document);
  _splitSentinelParagraphs(document);
  _ensureTrailingParagraph(document);
  return document;
}

/// 图片行与相邻行紧挨着时，补一个真正的空行隔开。
///
/// super_editor 的 markdown 解析器会把图片行并进**上一行**：
/// `- [ ] read book` 紧跟 `![](assets/n/1.jpg)` 时图片被当成任务续行，
/// 普通段落紧跟图片时图片也会消失（实测：重开笔记看不到图）。
/// 图片两侧只要有非空行就补空行；这些空行在 [_protectBlankLines] 之后
/// 插入，不会被转成哨兵，因此不会给文档多出空段落；序列化也不会写回
/// 这些临时空行（往返测试已覆盖）。
String _isolateImageLines(String md) {
  if (!md.contains('![')) {
    return md;
  }
  final RegExp imageLine = RegExp(r'^!\[[^\]]*\]\([^)\s]+\)[ \t\r]*$');
  final lines = md.split('\n');

  final out = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (!imageLine.hasMatch(line)) {
      out.add(line);
      continue;
    }
    if (out.isNotEmpty && out.last.trim().isNotEmpty) {
      out.add('');
    }
    out.add(line);
    if (i + 1 < lines.length && lines[i + 1].trim().isNotEmpty) {
      out.add('');
    }
  }
  return out.join('\n');
}

/// 空行哨兵。
///
/// markdown 的「空行」本身只是分段符，解析器不会产出空段落节点，于是
/// 「附件和图片之间手动留的空白行」一存一读就丢了（用户反馈）。这里在
/// 解析前把**内容之间的空行**替换成一个私有区字符占位行，解析后再把
/// 含占位符的段落拆回「空段落」，从而实现空行的往返保真。
///
/// 只用私有区字符、不进存储：序列化时空段落写回成真正的空行。
const String _blankParagraphSentinel = '\uE000';

/// 把内容之间的空行替换成哨兵行（代码块内部不动）。
String _protectBlankLines(String md) {
  if (!md.contains('\n\n')) {
    return md;
  }
  final lines = md.split('\n');
  var insideFence = false;
  final out = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.trimLeft().startsWith('```')) {
      insideFence = !insideFence;
      out.add(line);
      continue;
    }
    final isBlank = line.trim().isEmpty;
    // 首尾空行不产生空段落（存储里末尾留一个空行很常见）。
    final hasContentBefore = out.any((String l) => l.trim().isNotEmpty);
    final hasContentAfter = lines
        .skip(i + 1)
        .any((String l) => l.trim().isNotEmpty);
    // 列表/待办行旁边的空行不替换成哨兵：那属于列表的松散结构，
    // 占位符会被解析器并进列表项文本（保存后写回私有区字符，列表摘要
    // 显示成「☒」乱码），也可能把缩进结构带歪。
    final prevLine = out.isEmpty ? '' : out.last;
    var nextLine = '';
    for (var j = i + 1; j < lines.length; j++) {
      if (lines[j].trim().isNotEmpty) {
        nextLine = lines[j];
        break;
      }
    }
    final touchesList = _listLinePattern.hasMatch(prevLine) ||
        _listLinePattern.hasMatch(nextLine);
    if (!insideFence &&
        isBlank &&
        hasContentBefore &&
        hasContentAfter &&
        !touchesList) {
      out.add(_blankParagraphSentinel);
      continue;
    }
    out.add(line);
  }
  return out.join('\n');
}

/// 把含哨兵的段落拆成「文本段 + 空段落」的序列。
///
/// 只处理普通段落：引用/标题/代码块/列表/待办里的哨兵一律不动 ——
/// 那些节点的文本带缩进和标记语义，拆开反而会把层级带歪。
/// （列表旁边的空行已改为不替换哨兵，见 [_protectBlankLines]。）
void _splitSentinelParagraphs(MutableDocument document) {
  for (var i = 0; i < document.nodeCount; i++) {
    final node = document.getNodeAt(i);
    if (node is! ParagraphNode) {
      continue;
    }
    if (node.getMetadataValue(NodeMetadata.blockType) != null &&
        node.getMetadataValue(NodeMetadata.blockType) != paragraphAttribution) {
      continue;
    }
    final String plain = node.text.toPlainText();
    if (!plain.contains(_blankParagraphSentinel)) {
      continue;
    }

    final List<AttributedText> parts = <AttributedText>[];
    var offset = 0;
    var segmentStart = 0;
    for (final String line in plain.split('\n')) {
      if (line.trim() == _blankParagraphSentinel) {
        if (offset > segmentStart) {
          parts.add(_textSegment(node.text, segmentStart, offset - 1));
        }
        parts.add(AttributedText());
        segmentStart = offset + line.length + 1;
      }
      offset += line.length + 1;
    }
    if (segmentStart < plain.length) {
      parts.add(_textSegment(node.text, segmentStart, plain.length));
    }
    if (parts.isEmpty) {
      continue;
    }

    final int index = document.getNodeIndexById(node.id);
    final List<DocumentNode> nodes = <DocumentNode>[
      for (final AttributedText part in parts)
        ParagraphNode(id: Editor.createNodeId(), text: part),
    ];
    document.replaceNodeById(node.id, nodes.first);
    for (var k = 1; k < nodes.length; k++) {
      document.insertNodeAt(index + k, nodes[k]);
    }
    i = index + nodes.length - 1;
  }
}

/// 末尾始终补一个空段落。
///
/// 参考语雀：正文最底部永远留一行可点/可落光标的空白，否则最后一块是
/// 图片时（图片组件吃掉点击），既点不出光标也没法回车删除（用户反馈）。
/// 序列化时空段落不写盘，所以不会污染存储。
void _ensureTrailingParagraph(MutableDocument document) {
  if (document.nodeCount == 0) {
    document.insertNodeAt(
      0,
      ParagraphNode(id: Editor.createNodeId(), text: AttributedText()),
    );
    return;
  }
  final DocumentNode last = document.getNodeAt(document.nodeCount - 1)!;
  if (last is TextNode && last.text.isEmpty && last is ParagraphNode) {
    return;
  }
  document.insertNodeAt(
    document.nodeCount,
    ParagraphNode(id: Editor.createNodeId(), text: AttributedText()),
  );
}

/// 把「同一段落里夹着附件链接」的行拆成独立段落。
///
/// super_editor 的 markdown 解析器会把相邻的普通行并进同一个
/// ParagraphNode（文本里带 `\n`）。附件卡片要求整行只有一个链接，
/// 否则只能退回「蓝色下划线链接」的显示（用户反馈「附件显示有问题」）。
/// 这里按行切开，保留每段的行内样式与链接属性；序列化端逐行写回，
/// 落盘内容不变。
void _splitAttachmentLines(MutableDocument document) {
  for (var i = 0; i < document.nodeCount; i++) {
    final node = document.getNodeAt(i);
    if (node is! ParagraphNode) {
      continue;
    }
    // 只处理普通段落；引用/标题/代码块里的「附件行」不做拆分。
    final blockType = node.getMetadataValue(NodeMetadata.blockType);
    if (blockType != null && blockType != paragraphAttribution) {
      continue;
    }
    final plain = node.text.toPlainText();
    if (!plain.contains('\n')) {
      continue;
    }

    final lines = plain.split('\n');
    final links = <int, LinkAttribution>{};
    var offset = 0;
    for (var j = 0; j < lines.length; j++) {
      final lineStart = offset;
      final lineEnd = offset + lines[j].length;
      final link = _attachmentLinkInLine(node.text, lineStart, lineEnd);
      if (link != null) {
        links[j] = link;
      }
      offset = lineEnd + 1;
    }
    if (links.isEmpty) {
      continue;
    }

    final List<ParagraphNode> segments = <ParagraphNode>[];
    var segmentStart = 0;
    offset = 0;
    for (var j = 0; j < lines.length; j++) {
      final lineStart = offset;
      final lineEnd = offset + lines[j].length;
      final link = links[j];
      if (link != null) {
        var beforeEnd = lineStart;
        if (beforeEnd > segmentStart &&
            plain[beforeEnd - 1] == '\n') {
          beforeEnd--;
        }
        if (beforeEnd > segmentStart) {
          segments.add(
            _textSegmentNode(_textSegment(node.text, segmentStart, beforeEnd)),
          );
        }
        final raw = plain.substring(lineStart, lineEnd);
        final trimmed = raw.trim();
        if (trimmed.isNotEmpty) {
          final trimStart = lineStart + raw.indexOf(trimmed);
          segments.add(_textSegmentNode(_textSegment(
            node.text,
            trimStart,
            trimStart + trimmed.length,
          )));
        }
        segmentStart = lineEnd + 1;
      }
      offset = lineEnd + 1;
    }
    if (segmentStart < plain.length) {
      segments.add(
        _textSegmentNode(_textSegment(node.text, segmentStart, plain.length)),
      );
    }
    if (segments.length <= 1) {
      continue;
    }

    final index = document.getNodeIndexById(node.id);
    document.replaceNodeById(node.id, segments.first);
    for (var k = 1; k < segments.length; k++) {
      document.insertNodeAt(index + k, segments[k]);
    }
  }
}

/// 一行（含首尾空白）里是否有覆盖整行的附件链接。
LinkAttribution? _attachmentLinkInLine(
  AttributedText text,
  int lineStart,
  int lineEnd,
) {
  final raw = text.toPlainText().substring(lineStart, lineEnd);
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final start = lineStart + raw.indexOf(trimmed);
  final end = start + trimmed.length;
  for (final link
      in text.spans.getAllAttributionsAt(start).whereType<LinkAttribution>()) {
    if (!link.plainTextUri.startsWith('assets/')) {
      continue;
    }
    final range = text.spans.getAttributedRange({link}, start);
    if (range.start <= start && range.end >= end - 1) {
      return link;
    }
  }
  return null;
}

/// 从 [source] 切出 `[start, end)` 段落，保留区间内的行内属性。
AttributedText _textSegment(AttributedText source, int start, int end) {
  final plain = source.toPlainText();
  final AttributedText result = AttributedText(plain.substring(start, end));
  if (end <= start) {
    return result;
  }
  final spans = source.spans.getAttributionSpansInRange(
    attributionFilter: (Attribution _) => true,
    start: start,
    end: end - 1,
  );
  for (final span in spans) {
    final localStart = span.start - start;
    final localEnd = span.end - start;
    if (localStart < 0 || localEnd < localStart || localStart >= result.length) {
      continue;
    }
    result.addAttribution(
      span.attribution,
      SpanRange(
        localStart,
        localEnd >= result.length ? result.length - 1 : localEnd,
      ),
    );
  }
  return result;
}

ParagraphNode _textSegmentNode(AttributedText text) {
  return ParagraphNode(
    id: Editor.createNodeId(),
    text: text,
  );
}

/// 把「文本中带换行的 TaskNode」拆成 任务节点 + 后续段落节点。
///
/// markdown 解析器会把任务行后紧跟的非缩进段落并进任务文本
/// （lazy continuation），显示上段落会缩进挂在勾选框下面，很怪。
/// 按行拆开：首行留在任务里，其余每行一个段落，顺序插回任务之后。
/// 序列化端本来就把任务文本逐行写回，所以拆分不改变落盘内容。
void _splitMultilineTasks(MutableDocument document) {
  for (var i = 0; i < document.nodeCount; i++) {
    final node = document.getNodeAt(i);
    if (node is! TaskNode) {
      continue;
    }
    final plain = node.text.toPlainText();
    if (!plain.contains('\n')) {
      continue;
    }
    final lines = plain.split('\n');
    // 首行回填任务节点。
    document.replaceNodeById(
      node.id,
      TaskNode(
        id: node.id,
        text: AttributedText(lines.first.trim()),
        isComplete: node.isComplete,
        indent: node.indent,
      ),
    );
    var insertIndex = i + 1;
    for (final line in lines.skip(1)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      document.insertNodeAt(
        insertIndex,
        ParagraphNode(
          id: Editor.createNodeId(),
          text: AttributedText(trimmed),
        ),
      );
      insertIndex++;
    }
  }
}

/// 小记方言的 Document → Markdown 序列化器。
///
/// 为什么不用 super_editor 自带的 `serializeDocumentToMarkdown`：
/// 实测（0.3.0-dev.52）它不保真 —— 有序列表每项都写 `1.`、Task 文本
/// 与标记断行、`*` 替换 `-`、列表项之间插空行。用户数据不能被编辑器
/// 悄悄改写，这里按小记的存储规范自己输出：
///  - 块与块之间不加空行（与旧版 md 文件的紧凑行式存储一致）；
///  - 列表嵌套缩进 = 两个空格 × 层级；有序编号 = 同层连续计数（模型里
///    没有原始编号，输出即规范化编号）；
///  - 无序列表一律 `-`；待办 `- [ ]` / `- [x]`；引用 `> `；
///    代码块 ``` 围栏；图片 `![alt](url)`；分隔线 `---`；
///  - 行内样式（粗体/斜体/删除线/行内码/链接）从 AttributedText 的
///    spans 重建回 md 记号。
///
/// 已知取舍：行内样式的组合顺序以「粗体 → 斜体 → 删除线 → 行内码 → 高亮」
/// 输出；有序列表起始编号通过节点 metadata 保留（见 [kOrderedStartMetadata]）。
String serializeDocumentToXiaojiMarkdown(Document document) {
  final out = StringBuffer();
  // 每一层列表项的「标记宽度」（如 `1. `=3、`- `=2）。CommonMark 要求
  // 子项缩进 ≥ 父项标记宽度，固定两个空格在 `2. ` 之类的父项下会被当成
  // 续行而不是子列表（实测），所以缩进按各级标记宽度累加。
  final markerWidths = <int>[];

  /// 待写入的空行数量（空段落 → 一行空行，末尾的自动丢弃）。
  ///
  /// 之前直接跳过空段落，导致「附件和图片之间手动留的空白行」一存一读
  /// 就消失（用户反馈）。这里把空段落累积成空行，只在其后还有内容时
  /// 写出，末尾空段落不写盘。
  var pendingBlanks = 0;

  String indentForDepth(int depth) {
    var width = 0;
    for (var i = 0; i < depth && i < markerWidths.length; i++) {
      width += markerWidths[i];
    }
    return ' ' * width;
  }

  void write(String line) {
    if (out.isNotEmpty) {
      out.write('\n');
    }
    out.write(line);
  }

  for (final node in document) {
    // 普通空段落：记一笔空行，等下一个内容块出现时一起写出。
    if (node is ParagraphNode &&
        node.text.isEmpty &&
        (node.getMetadataValue(NodeMetadata.blockType) ??
                paragraphAttribution) ==
            paragraphAttribution) {
      if (out.isNotEmpty) {
        pendingBlanks += 1;
      }
      continue;
    }
    if (pendingBlanks > 0) {
      for (var i = 0; i < pendingBlanks; i++) {
        write('');
      }
      pendingBlanks = 0;
    }
    if (node is ListItemNode) {
      // 深度回浅：弹出多余层级。
      while (markerWidths.length > node.indent) {
        markerWidths.removeLast();
      }
      final indent = indentForDepth(node.indent);
      if (node.type == ListItemType.ordered) {
        // 编号 = run 起始编号 + 层内序号 - 1（`5.` 开头不会再被写成 `1.`）。
        final ({int ordinal, int start})? number =
            orderedListItemNumber(document, node);
        final int value = number == null
            ? 1
            : number.start + number.ordinal - 1;
        final marker = '$value. ';
        markerWidths.add(marker.length);
        write('$indent$marker${_inlineMarkdown(node.text)}');
      } else {
        markerWidths.add('- '.length);
        write('$indent- ${_inlineMarkdown(node.text)}');
      }
      continue;
    }
    if (node is TaskNode) {
      while (markerWidths.length > node.indent) {
        markerWidths.removeLast();
      }
      // 父级可能是非列表块（栈被清空）：补齐缺失层级的标记宽度，
      // 否则 `indentForDepth` 会算出 0，嵌套待办写回后变成顶层。
      while (markerWidths.length < node.indent) {
        markerWidths.add('- '.length);
      }
      final mark = node.isComplete ? 'x' : ' ';
      // markdown 解析器给任务文本带前导换行（实测），trim 掉。
      final text = _inlineMarkdown(node.text).trim();
      write('${indentForDepth(node.indent)}- [$mark] $text');
      // 待办行也是列表项：压入自身标记宽度，子项才能算对缩进。
      markerWidths.add('- '.length);
      continue;
    }
    // 非列表块：清空层级状态。
    markerWidths.clear();
    if (node is ImageNode) {
      write('![${node.altText}](${node.imageUrl})');
      continue;
    }
    if (node is HorizontalRuleNode) {
      write('---');
      continue;
    }
    if (node is TableBlockNode) {
      final String? table = _tableMarkdown(node);
      if (table != null) {
        write(table);
      }
      continue;
    }
    if (node is ParagraphNode) {
      final blockType = node.getMetadataValue('blockType');
      final plain = node.text.toPlainText();
      if (blockType == header1Attribution) {
        write('# ${_inlineMarkdown(node.text)}');
        continue;
      }
      if (blockType == header2Attribution) {
        write('## ${_inlineMarkdown(node.text)}');
        continue;
      }
      if (blockType == header3Attribution) {
        write('### ${_inlineMarkdown(node.text)}');
        continue;
      }
      if (blockType == header4Attribution) {
        write('#### ${_inlineMarkdown(node.text)}');
        continue;
      }
      if (blockType == header5Attribution) {
        write('##### ${_inlineMarkdown(node.text)}');
        continue;
      }
      if (blockType == header6Attribution) {
        write('###### ${_inlineMarkdown(node.text)}');
        continue;
      }
      if (blockType == blockquoteAttribution) {
        // 引用的每一行都要带 `> `：只给首行加前缀时，后续行靠 CommonMark
        // 的 lazy continuation 才勉强算引用，但任何按行解析的消费方（列表
        // 摘要的引用块分组）都会把它当成普通段落（实测首页引用的第二行
        // 掉出蓝底块）。
        for (final line in _inlineMarkdown(node.text).split('\n')) {
          write('> $line');
        }
        continue;
      }
      if (blockType == codeAttribution) {
        // 代码块：围栏包裹，保留语言标记；内容里出现 ``` 时自动加长围栏，
        // 否则片段里的一段示例代码会把围栏提前闭合、把后半段挤成正文。
        //
        // 解析器会给代码文本补一个结尾换行，直接按行写回会多出一行空行，
        // 往返回合会让空行越积越多 —— 这里先去掉结尾换行。
        final String code = plain.replaceFirst(RegExp(r'\n+$'), '');
        final String language =
            (node.getMetadataValue(kCodeLanguageMetadata) as String?)?.trim() ??
                '';
        final String fence = _codeFenceFor(code);
        write('$fence$language');
        for (final line in code.split('\n')) {
          write(line);
        }
        write(fence);
        continue;
      }
      // 普通段落：空段落跳过（不产出空行，存储保持紧凑）。
      if (plain.isEmpty) {
        continue;
      }
      write(_inlineMarkdown(node.text));
      continue;
    }
    // 未知节点类型：尽力输出纯文本，绝不丢字。
    if (node is TextNode) {
      final text = _inlineMarkdown(node.text);
      if (text.isNotEmpty) {
        write(text);
      }
    }
  }

  // 兜底：哨兵只用于解析期占位，绝不能写进用户文件。
  // 正常路径在 _splitSentinelParagraphs 已全部还原成空段落；这里再剥一次，
  // 避免未来新增节点类型时哨兵泄漏成「☒」乱码。
  return out.toString().replaceAll(_blankParagraphSentinel, '');
}

/// 代码围栏长度：内容里最长的一串反引号再加 1，至少 3。
///
/// 例：代码里本身有 ``` 时输出 ````（4 个），解析器就不会提前闭合。
String _codeFenceFor(String content) {
  var length = 3;
  for (final RegExpMatch match
      in RegExp(r'^[ \t]*(`{3,})', multiLine: true).allMatches(content)) {
    final int run = match.group(1)!.length + 1;
    if (run > length) {
      length = run;
    }
  }
  return '`' * length;
}

/// 表格 → GFM 管道表格。
///
/// super_editor 的表格模型只存单元格文本与对齐，没有合并单元格；表头
/// 固定是第 0 行，必须写出分隔行，否则重新解析会退化成普通段落。
String? _tableMarkdown(TableBlockNode node) {
  if (node.rowCount == 0 || node.columnCount == 0) {
    return null;
  }
  final int columns = node.columnCount;
  final List<List<String>> rows = <List<String>>[
    for (int r = 0; r < node.rowCount; r++)
      <String>[
        for (int c = 0; c < columns; c++)
          _tableCellMarkdown(node.getCell(rowIndex: r, columnIndex: c)),
      ],
  ];
  final StringBuffer buffer = StringBuffer('| ${rows.first.join(' | ')} |');
  // 对齐信息存在数据行单元格的 textAlign 上（解析器从表头 align 复制）；
  // 只有表头行时无法还原，统一按默认左对齐输出。
  final List<String> separators = <String>[
    for (int c = 0; c < columns; c++)
      _tableSeparator(
        node.rowCount > 1 ? node.getCell(rowIndex: 1, columnIndex: c) : null,
      ),
  ];
  buffer.write('\n| ${separators.join(' | ')} |');
  for (int r = 1; r < rows.length; r++) {
    buffer.write('\n| ${rows[r].join(' | ')} |');
  }
  return buffer.toString();
}

/// 单元格里的换行与裸 `|` 会破坏管道语法，换成空格与转义；行内样式保留。
String _tableCellMarkdown(TextNode cell) {
  return _inlineMarkdown(cell.text)
      .replaceAll('\n', ' ')
      .replaceAll('|', r'\|')
      .trim();
}

/// 分隔行：`:---` 左对齐、`:---:` 居中、`---:` 右对齐、`---` 默认。
String _tableSeparator(TextNode? firstDataCell) {
  final Object? align = firstDataCell?.metadata[TextNodeMetadata.textAlign];
  return switch (align) {
    'center' => ':---:',
    'right' => '---:',
    'left' => ':---',
    _ => '---',
  };
}

/// 把 [AttributedText] 的行内样式重建回 markdown 记号。
///
/// 逐字符扫描：相邻字符的样式集合变化处输出标记的进入/退出符号。
/// 支持粗体、斜体、删除线、行内码、链接（链接用 getAttributedRange
/// 拿整段区间，一次性输出 `[文本](url)`）。
String _inlineMarkdown(AttributedText attributed) {
  final plain = attributed.toPlainText();
  final spans = attributed.spans;
  final out = StringBuffer();

  final markerOrder = <Attribution, String>{
    boldAttribution: '**',
    italicsAttribution: '*',
    strikethroughAttribution: '~~',
    codeAttribution: '`',
    highlightAttribution: '==',
  };

  var openMarkers = <Attribution>[];
  var i = 0;
  while (i < plain.length) {
    // 链接优先：整段区间一次性输出。
    final linkHere = spans
        .getAllAttributionsAt(i)
        .whereType<LinkAttribution>()
        .firstOrNull;
    if (linkHere != null) {
      // 关闭此前打开的标记，链接结束后不再自动重开（组合罕见，简化处理）。
      for (final marker in openMarkers.reversed) {
        out.write(markerOrder[marker]);
      }
      openMarkers = <Attribution>[];
      final range = spans.getAttributedRange({linkHere}, i);
      final start = range.start.clamp(0, plain.length);
      final end = (range.end + 1).clamp(0, plain.length);
      final inner = plain.substring(start, end);
      final String title =
          linkHere is XiaojiLinkAttribution ? linkHere.title : '';
      final String suffix =
          title.isEmpty ? '' : ' "${title.replaceAll('"', r'\"')}"';
      out.write('[$inner](${linkHere.plainTextUri}$suffix)');
      i = end;
      continue;
    }

    // 行内码整段输出：内容里自带反引号时要用更长的围栏，
    // 否则 ``a `b` c`` 会被写成 `a `b` c`，下次解析直接断掉。
    if (spans.hasAttributionAt(i, attribution: codeAttribution)) {
      for (final marker in openMarkers.reversed) {
        out.write(markerOrder[marker]);
      }
      openMarkers = <Attribution>[];
      var end = i;
      while (end < plain.length &&
          spans.hasAttributionAt(end, attribution: codeAttribution)) {
        end++;
      }
      final String content = plain.substring(i, end);
      var longest = 0;
      for (final RegExpMatch run in RegExp(r'`+').allMatches(content)) {
        if (run.group(0)!.length > longest) {
          longest = run.group(0)!.length;
        }
      }
      final String fence = '`' * (longest + 1);
      // CommonMark：内容首尾是反引号时，围栏与内容之间各留一个空格。
      final String pad =
          content.startsWith('`') || content.endsWith('`') ? ' ' : '';
      out.write('$fence$pad$content$pad$fence');
      i = end;
      continue;
    }

    final current = spans
        .getAllAttributionsAt(i)
        .where((a) => markerOrder.containsKey(a))
        .toList();
    if (!_sameSet(current, openMarkers)) {
      // 关闭不再存在的（逆序），打开新增的（正序）。
      for (final marker in openMarkers.reversed) {
        if (!current.contains(marker)) {
          out.write(markerOrder[marker]);
        }
      }
      for (final marker in markerOrder.keys) {
        if (current.contains(marker) && !openMarkers.contains(marker)) {
          out.write(markerOrder[marker]);
        }
      }
      openMarkers = current;
    }
    if (_needsLiteralEscape(plain, i, current)) {
      out.write(r'\');
    }
    out.write(plain[i]);
    i++;
  }
  for (final marker in openMarkers.reversed) {
    out.write(markerOrder[marker]);
  }
  return out.toString();
}

/// 这个字符是不是「普通正文里的语法字符」，需要转义后才不会在下次
/// 解析时被当成格式标记。
///
/// 例：用户输入的 `*斜体*` 如果并没有斜体属性（是用 `\*` 转义输入的），
/// 原样写回会变成真斜体 —— 必须输出 `\*斜体\*`。被对应属性覆盖的字符
/// 本来就会被包在标记里，不再单独转义。
bool _needsLiteralEscape(String text, int index, List<Attribution> active) {
  final String ch = text[index];
  switch (ch) {
    case r'\':
    case '`':
      return true;
    case '*':
      return !active.contains(boldAttribution) &&
          !active.contains(italicsAttribution);
    case '~':
      return !active.contains(strikethroughAttribution);
    case '=':
      if (active.contains(highlightAttribution)) {
        return false;
      }
      final bool prev = index > 0 && text[index - 1] == '=';
      final bool next = index + 1 < text.length && text[index + 1] == '=';
      return prev || next;
    default:
      return false;
  }
}

bool _sameSet(List<Attribution> a, List<Attribution> b) {
  if (a.length != b.length) {
    return false;
  }
  for (final item in a) {
    if (!b.contains(item)) {
      return false;
    }
  }
  return true;
}
