import 'package:super_editor/super_editor.dart';

import 'xiaoji_markdown.dart';

/// 手动输入 Markdown 行内标记的识别（纯函数，便于单测）。
///
/// 竞品（Typora / Obsidian / 语雀）的共识是「闭合标记一敲完就成型」：
/// 输入 `**重点**` 的最后一个 `*` 时，文字立刻变粗、标记字符消失。
/// 小记此前只有工具条能加行内样式，手打标记会原样留在正文里，
/// 用户反馈「md 标签没有识别到」，这里补齐。
///
/// 只识别「光标正好在闭合标记之后」这一种情况：不做全文扫描，避免把
/// 已有正文里作为普通文本出现的 `*` / `==` 误改成样式。
enum InlineMarkdownKind { bold, italic, code, strikethrough, highlight, link }

class InlineMarkdownMatch {
  const InlineMarkdownMatch({
    required this.kind,
    required this.openStart,
    required this.openLength,
    required this.contentStart,
    required this.contentEnd,
    required this.closeLength,
    this.linkUrl,
  });

  final InlineMarkdownKind kind;

  /// 起始标记在原文中的起点。
  final int openStart;

  /// 起始标记长度（`**` 为 2，`` ` `` 为 1，链接的 `[` 为 1）。
  final int openLength;

  /// 内容区间（不含标记）。删除标记后，内容新起点为
  /// `contentStart - openLength`。
  final int contentStart;
  final int contentEnd;

  /// 闭合标记长度（`](url)` 的链接会大于 1）。
  final int closeLength;

  /// [InlineMarkdownKind.link] 的地址。
  final String? linkUrl;

  /// 删除标记后内容的新起点。
  int get newContentStart => contentStart - openLength;

  /// 删除标记后内容的新终点（光标落点：继续输入应接在样式文字之后）。
  ///
  /// [contentEnd] 已经是闭合标记之前的位置，只需再减去起始标记长度。
  int get newContentEnd => contentEnd - openLength;

  /// 命中项对应的 attribution；链接需要 URL，单独处理。
  Attribution? get attribution => switch (kind) {
        InlineMarkdownKind.bold => boldAttribution,
        InlineMarkdownKind.italic => italicsAttribution,
        InlineMarkdownKind.code => codeAttribution,
        InlineMarkdownKind.strikethrough => strikethroughAttribution,
        InlineMarkdownKind.highlight => highlightAttribution,
        InlineMarkdownKind.link => null,
      };
}

/// `[文字](https://…)`：必须正好结束在光标处。
final RegExp _linkPattern = RegExp(r'\[([^\[\]\n]+)\]\(([^()\n\s]+)\)$');

/// 识别光标前刚刚闭合的行内标记；不匹配返回 null。
///
/// [caret] 为光标偏移（UTF-16），[text] 为当前段落纯文本。
InlineMarkdownMatch? matchInlineMarkdown(String text, int caret) {
  if (caret <= 0 || caret > text.length) {
    return null;
  }

  // 链接优先：闭合形态是 `](url)` 而不是重复字符。
  final String before = text.substring(0, caret);
  final RegExpMatch? link = _linkPattern.firstMatch(before);
  if (link != null) {
    final int labelEnd = link.start + link.group(0)!.indexOf(']');
    return InlineMarkdownMatch(
      kind: InlineMarkdownKind.link,
      openStart: link.start,
      openLength: 1,
      contentStart: link.start + 1,
      contentEnd: labelEnd,
      closeLength: caret - labelEnd,
      linkUrl: link.group(2),
    );
  }

  // `**加粗**`：先判双字符，避免被单字符斜体截胡。
  final InlineMarkdownMatch? bold =
      _matchPaired(text, caret, '**', InlineMarkdownKind.bold);
  if (bold != null) {
    return bold;
  }
  final InlineMarkdownMatch? strike =
      _matchPaired(text, caret, '~~', InlineMarkdownKind.strikethrough);
  if (strike != null) {
    return strike;
  }
  final InlineMarkdownMatch? highlight =
      _matchPaired(text, caret, '==', InlineMarkdownKind.highlight);
  if (highlight != null) {
    return highlight;
  }
  final InlineMarkdownMatch? code = _matchCode(text, caret);
  if (code != null) {
    return code;
  }
  return _matchItalic(text, caret);
}

/// 成对标记（`**` / `~~` / `==`）。
InlineMarkdownMatch? _matchPaired(
  String text,
  int caret,
  String marker,
  InlineMarkdownKind kind,
) {
  final int length = marker.length;
  if (caret < length * 2) {
    return null;
  }
  if (text.substring(caret - length, caret) != marker) {
    return null;
  }
  // `***` / `~~~` 这类连续标记不处理，避免和「下一个标记的开头」抢。
  if (caret >= length * 2 + 1 &&
      text.substring(caret - length - 1, caret - length) == marker[0]) {
    return null;
  }
  final int contentEnd = caret - length;
  // 起始标记必须在闭合标记之前，且中间不能夹同类标记（简化实现）。
  final int openIndex = text.lastIndexOf(marker, contentEnd - length);
  if (openIndex < 0) {
    return null;
  }
  final int contentStart = openIndex + length;
  final String content = text.substring(contentStart, contentEnd);
  if (content.isEmpty || content.trim().isEmpty) {
    return null;
  }
  if (content.contains(marker)) {
    return null;
  }
  if (content.startsWith(' ') || content.endsWith(' ')) {
    return null;
  }
  return InlineMarkdownMatch(
    kind: kind,
    openStart: openIndex,
    openLength: length,
    contentStart: contentStart,
    contentEnd: contentEnd,
    closeLength: length,
  );
}

/// `` `行内码` ``：单反引号，排除 ``` 与 `` ``。
InlineMarkdownMatch? _matchCode(String text, int caret) {
  if (caret < 2 || text[caret - 1] != '`') {
    return null;
  }
  if (text[caret - 2] == '`') {
    return null;
  }
  final int contentEnd = caret - 1;
  int openIndex = -1;
  for (int i = contentEnd - 1; i >= 0; i--) {
    if (text[i] != '`') {
      continue;
    }
    if (i > 0 && text[i - 1] == '`') {
      continue;
    }
    openIndex = i;
    break;
  }
  if (openIndex < 0) {
    return null;
  }
  final String content = text.substring(openIndex + 1, contentEnd);
  if (content.isEmpty || content.trim().isEmpty) {
    return null;
  }
  if (content.contains('`')) {
    return null;
  }
  return InlineMarkdownMatch(
    kind: InlineMarkdownKind.code,
    openStart: openIndex,
    openLength: 1,
    contentStart: openIndex + 1,
    contentEnd: contentEnd,
    closeLength: 1,
  );
}

/// `*斜体*`：单星号，且两侧不能是 `**`。
InlineMarkdownMatch? _matchItalic(String text, int caret) {
  if (caret < 2 || text[caret - 1] != '*') {
    return null;
  }
  if (text[caret - 2] == '*') {
    return null;
  }
  final int contentEnd = caret - 1;
  int openIndex = -1;
  for (int i = contentEnd - 1; i >= 0; i--) {
    if (text[i] != '*') {
      continue;
    }
    // 跳过 `**` 的一部分。
    if (i > 0 && text[i - 1] == '*') {
      continue;
    }
    openIndex = i;
    break;
  }
  if (openIndex < 0) {
    return null;
  }
  final String content = text.substring(openIndex + 1, contentEnd);
  if (content.isEmpty || content.trim().isEmpty) {
    return null;
  }
  if (content.contains('*')) {
    return null;
  }
  if (content.startsWith(' ') || content.endsWith(' ')) {
    return null;
  }
  return InlineMarkdownMatch(
    kind: InlineMarkdownKind.italic,
    openStart: openIndex,
    openLength: 1,
    contentStart: openIndex + 1,
    contentEnd: contentEnd,
    closeLength: 1,
  );
}

/// 把一次行内标记命中翻译成内核编辑请求；没有命中返回 null。
///
/// 顺序：先给内容打属性，再删闭合标记、起始标记（两段都用原始下标，
/// 互不影响），最后把光标放到内容末尾。一次 execute 内完成，
/// 用户看到的就是「敲完闭合标记即时成型」。
List<EditRequest>? inlineMarkdownRequests({
  required String nodeId,
  required String text,
  required int caret,
}) {
  final InlineMarkdownMatch? match = matchInlineMarkdown(text, caret);
  if (match == null) {
    return null;
  }
  DocumentPosition at(int offset) => DocumentPosition(
        nodeId: nodeId,
        nodePosition: TextNodePosition(offset: offset),
      );
  final Set<Attribution> attributions = match.kind == InlineMarkdownKind.link
      ? <Attribution>{LinkAttribution(match.linkUrl!)}
      : <Attribution>{match.attribution!};
  return <EditRequest>[
    AddTextAttributionsRequest(
      documentRange: DocumentRange(
        start: at(match.contentStart),
        end: at(match.contentEnd),
      ),
      attributions: attributions,
    ),
    DeleteContentRequest(
      documentRange: DocumentRange(
        start: at(match.contentEnd),
        end: at(match.contentEnd + match.closeLength),
      ),
    ),
    DeleteContentRequest(
      documentRange: DocumentRange(
        start: at(match.openStart),
        end: at(match.openStart + match.openLength),
      ),
    ),
    ChangeSelectionRequest(
      DocumentSelection.collapsed(position: at(match.newContentEnd)),
      SelectionChangeType.placeCaret,
      SelectionReason.userInteraction,
    ),
  ];
}

/// 整段扫描用的合并模式：按「链接 → 行内码 → 加粗 → 删除线 → 高亮 →
/// 斜体」的优先级排列，正则天然取最左命中且不重叠，避免 `**粗**` 被
/// 斜体规则截胡。
///
/// 同时认 `__加粗__` / `_斜体_` 这两种下划线写法：内核的 Markdown 解析器
/// 支持它们（重进笔记就会渲染），但旧版粘贴补齐只认星号，于是出现
/// 「有些 md 标签重进才生效」。下划线要求两侧不是单词字符，避免把
/// `snake_case_name` 误当斜体。
final RegExp _scanPattern = RegExp(
  r'\[([^\[\]\n]+)\]\(([^()\n\s]+)\)'
  r'|`([^`\n]+)`'
  r'|\*\*([^*\n]+)\*\*'
  r'|~~([^~\n]+)~~'
  r'|==([^=\n]+)=='
  r'|(?<!\*)\*([^*\n]+)\*(?!\*)'
  r'|(?<![\w*])__([^_\n]+)__(?![\w*])'
  r'|(?<![\w_])_([^_\n]+)_(?![\w_])',
);

/// 标记内容是否有效：非空、首尾不能是空白（`2 * 3 * 4` 这类不算斜体）。
bool _isInlineContent(String content) =>
    content.trim().isNotEmpty && content.trim() == content;

/// 整段扫描所有**已闭合**的行内标记（按出现顺序、互不重叠）。
///
/// 与 [matchInlineMarkdown] 的区别：后者只看「光标前刚闭合的那一个」，
/// 用于手打即时成型；这里扫整段文本，用于粘贴 / 一次性插入之后补齐样式
/// —— 否则 `**粗体**` 会以字面量留在正文里，只能存盘重进才被解析。
List<InlineMarkdownMatch> findAllInlineMarkdown(String text) {
  if (text.isEmpty) {
    return const <InlineMarkdownMatch>[];
  }
  final List<InlineMarkdownMatch> matches = <InlineMarkdownMatch>[];
  for (final RegExpMatch match in _scanPattern.allMatches(text)) {
    final String? url = match.group(2);
    if (url != null) {
      final String label = match.group(1)!;
      matches.add(
        InlineMarkdownMatch(
          kind: InlineMarkdownKind.link,
          openStart: match.start,
          openLength: 1,
          contentStart: match.start + 1,
          contentEnd: match.start + 1 + label.length,
          closeLength: match.end - (match.start + 1 + label.length),
          linkUrl: url,
        ),
      );
      continue;
    }
    final InlineMarkdownKind kind;
    final int length;
    final String content;
    if (match.group(3) != null) {
      kind = InlineMarkdownKind.code;
      length = 1;
      content = match.group(3)!;
    } else if (match.group(4) != null) {
      kind = InlineMarkdownKind.bold;
      length = 2;
      content = match.group(4)!;
    } else if (match.group(5) != null) {
      kind = InlineMarkdownKind.strikethrough;
      length = 2;
      content = match.group(5)!;
    } else if (match.group(6) != null) {
      kind = InlineMarkdownKind.highlight;
      length = 2;
      content = match.group(6)!;
    } else if (match.group(8) != null) {
      kind = InlineMarkdownKind.bold;
      length = 2;
      content = match.group(8)!;
    } else if (match.group(9) != null) {
      kind = InlineMarkdownKind.italic;
      length = 1;
      content = match.group(9)!;
    } else {
      kind = InlineMarkdownKind.italic;
      length = 1;
      content = match.group(7)!;
    }
    if (!_isInlineContent(content)) {
      continue;
    }
    matches.add(
      InlineMarkdownMatch(
        kind: kind,
        openStart: match.start,
        openLength: length,
        contentStart: match.start + length,
        contentEnd: match.end - length,
        closeLength: length,
      ),
    );
  }
  return matches;
}

/// 整段文本 → 一批编辑请求；没有可转换的标记返回 null。
///
/// 请求按**从右到左**排列：同一 `execute` 内先删靠后的闭合标记，靠前的
/// 命中项下标仍然指向原文，不用做偏移换算。样式先加、标记后删，删标记
/// 不会波及内容区间。`caret` 给出时按实际删除量映射回新位置。
List<EditRequest>? allInlineMarkdownRequests({
  required String nodeId,
  required String text,
  int? caret,
}) {
  final List<InlineMarkdownMatch> matches = findAllInlineMarkdown(text);
  if (matches.isEmpty) {
    return null;
  }
  DocumentPosition at(int offset) => DocumentPosition(
        nodeId: nodeId,
        nodePosition: TextNodePosition(offset: offset),
      );
  final List<EditRequest> requests = <EditRequest>[];
  for (final InlineMarkdownMatch match in matches.reversed) {
    final Set<Attribution> attributions = match.kind == InlineMarkdownKind.link
        ? <Attribution>{LinkAttribution(match.linkUrl!)}
        : <Attribution>{match.attribution!};
    requests
      ..add(
        AddTextAttributionsRequest(
          documentRange: DocumentRange(
            start: at(match.contentStart),
            end: at(match.contentEnd),
          ),
          attributions: attributions,
        ),
      )
      ..add(
        DeleteContentRequest(
          documentRange: DocumentRange(
            start: at(match.contentEnd),
            end: at(match.contentEnd + match.closeLength),
          ),
        ),
      )
      ..add(
        DeleteContentRequest(
          documentRange: DocumentRange(
            start: at(match.openStart),
            end: at(match.openStart + match.openLength),
          ),
        ),
      );
  }
  if (caret != null) {
    int mapped = caret;
    for (final InlineMarkdownMatch match in matches) {
      final int removedEnd = match.contentEnd + match.closeLength;
      if (removedEnd <= caret) {
        // 标记整体在光标之前：起始 + 闭合标记都删掉了。
        mapped -= match.openLength + match.closeLength;
      } else if (caret > match.openStart && caret <= match.contentEnd) {
        // 光标落在内容里：只扣掉起始标记。
        mapped -= match.openLength;
      }
    }
    requests.add(
      ChangeSelectionRequest(
        DocumentSelection.collapsed(position: at(mapped)),
        SelectionChangeType.placeCaret,
        SelectionReason.userInteraction,
      ),
    );
  }
  return requests;
}

/// 整段文本是否为分割线（`---` / `***` / `___`）；用于「回车生成分割线」。
///
/// 还要认「智能连字符」：macOS 与多数输入法会把连续输入的连字符自动
/// 替换成 en dash（`–`）或 em dash（`—`），用户敲 `--` / `---` 后正文里
/// 已经没有任何 `-`，只按 ASCII 判断会永远识别不出来（用户实测）。
/// 破折号按视觉宽度折算：`–` = 2 个连字符，`—` / `―` = 3 个。
bool isHorizontalRuleLine(String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) {
    return false;
  }
  if (RegExp(r'^(?:-{3,}|\*{3,}|_{3,})$').hasMatch(trimmed)) {
    return true;
  }
  int width = 0;
  for (final int rune in trimmed.runes) {
    switch (rune) {
      case 0x2D: // -
        width += 1;
      case 0x2013: // –
        width += 2;
      case 0x2014: // —
        width += 3;
      case 0x2015: // ―
        width += 3;
      default:
        return false;
    }
  }
  return width >= 3;
}

/// 代码围栏开头（` ``` ` / ` ```dart `）；用于「回车生成代码块」。
///
/// 只认整段文本恰好是围栏：` ```dart ` 后面再跟内容说明用户是在写正文。
String? matchCodeFenceOpening(String text) {
  final RegExpMatch? match =
      RegExp(r'^\s*```([A-Za-z0-9_+#.-]*)\s*$').firstMatch(text);
  if (match == null) {
    return null;
  }
  return match.group(1) ?? '';
}
