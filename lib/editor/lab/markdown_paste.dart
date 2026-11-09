import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/super_editor.dart';

import 'html_to_markdown.dart';
import 'xiaoji_markdown.dart';

/// 剪贴板内容：纯文本 + 可选的 HTML。
class ClipboardContent {
  const ClipboardContent({required this.text, this.html});

  final String text;
  final String? html;
}

/// 剪贴板读取器。
///
/// Flutter 自带的 [Clipboard] 在 Android 上只能取 `text/plain`；网页复制
/// 往往同时带 `text/html`，这里通过原生通道补上，拿不到就退回纯文本。
class ClipboardReader {
  const ClipboardReader();

  static const MethodChannel _channel = MethodChannel('xiaoji/clipboard');

  Future<ClipboardContent> read() async {
    String text = '';
    try {
      final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text ?? '';
    } catch (error) {
      debugPrint('读取剪贴板纯文本失败: $error');
    }

    String? html;
    try {
      html = await _channel.invokeMethod<String>('getHtml');
    } catch (error) {
      debugPrint('读取剪贴板 HTML 失败: $error');
    }
    return ClipboardContent(text: text, html: html);
  }
}

/// 纯文本是否具备明显的 Markdown 结构。
///
/// 判定分两档，刻意避免误伤普通聊天文本（用户实测反馈「把聊天记录
/// 拆成了列表」）：
///  - **强信号**（任一命中即解析）：代码围栏、ATX 标题、setext 标题、
///    GFM 表格、待办项、引用行、链接 / 图片 / 加粗 / 删除线 / 行内码 /
///    高亮等行内标记；
///  - **弱信号**（至少两处）：普通无序 / 有序列表项 —— 一行以 `-` 开头的
///    回复仍按纯文本粘贴。
bool looksLikeMarkdown(String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) {
    return false;
  }
  final List<String> lines = trimmed.split('\n');
  // GFM 表格是强信号：`| a | b |` 紧跟 `| --- | --- |` 就必须按 Markdown
  // 解析，否则管道行会被当成普通正文（旧版实测）。
  if (_hasGfmTable(lines)) {
    return true;
  }

  int listMarkers = 0;
  for (var i = 0; i < lines.length; i++) {
    final String left = lines[i].trimLeft();
    if (left.isEmpty) {
      continue;
    }
    // 代码围栏本身就是强信号，单行也按 Markdown 处理。
    if (left.startsWith('```') || left.startsWith('~~~')) {
      return true;
    }
    // 标题是强信号：`## 小节` 单独出现也应当解析。
    if (RegExp(r'^#{1,6}\s').hasMatch(left)) {
      return true;
    }
    // setext 标题：上一行是正文、这一行全是 = 或 -。
    if (i > 0 &&
        RegExp(r'^\s{0,3}(?:=+|-{2,})\s*$').hasMatch(left) &&
        lines[i - 1].trim().isNotEmpty) {
      return true;
    }
    // 待办项 `- [ ]` / `- [x]` 结构明确，单行也识别（语雀/Notion 常见）。
    if (RegExp(r'^[-*+]\s+\[[ xX]\]\s').hasMatch(left)) {
      return true;
    }
    // 引用符号 `>` 是行首独有结构，单行也识别。
    if (RegExp(r'^>\s?').hasMatch(left)) {
      return true;
    }
    if (RegExp(r'^([-*+])\s+').hasMatch(left) ||
        RegExp(r'^\d+[.)]\s+').hasMatch(left)) {
      listMarkers++;
    }
  }
  if (listMarkers >= 2) {
    return true;
  }
  // 行内标记：出现即说明原文是 Markdown，而不是随手敲的句子。
  return RegExp(r'!\[[^\]]*\]\([^)]+\)').hasMatch(trimmed) ||
      RegExp(r'\[[^\]]+\]\([^)]+\)').hasMatch(trimmed) ||
      RegExp(r'\*\*[^*\n]+\*\*').hasMatch(trimmed) ||
      RegExp(r'~~[^~\n]+~~').hasMatch(trimmed) ||
      RegExp(r'==[^=\n]+==').hasMatch(trimmed) ||
      RegExp(r'`[^`\n]+`').hasMatch(trimmed);
}

/// 输入法的一次插入是否应视为「粘贴」并走 Markdown 解析。
///
/// [clipboardText] / [clipboardHtml] 是页面缓存的剪贴板快照，可能已经过期：
/// 应用内复制、输入法自带剪贴板都不会触发重新读取。因此分两条判定：
///  1. 与快照对得上 —— 正常粘贴，HTML / Markdown 结构任一即可；
///  2. 快照对不上（过期）但插入文本本身结构明确 —— 直接按纯文本解析，
///     不依赖 HTML。否则这类粘贴会退回默认纯文本，只能退出重进才解析。
bool shouldTreatImeInsertAsPaste(
  String inserted, {
  String? clipboardText,
  String? clipboardHtml,
}) {
  final String incoming = inserted.trim();
  if (incoming.isEmpty) {
    return false;
  }
  final String? snapshot = clipboardText?.trim();
  final bool matchesSnapshot = snapshot != null &&
      snapshot.isNotEmpty &&
      clipboardTextsMatch(incoming, snapshot);
  if (matchesSnapshot) {
    // 与当前剪贴板一致：只要带 HTML 或本身是 Markdown 就拦截。这里不再
    // 要求 20 字以上 —— 复制一条短待办（`- [ ] 买菜`）或短标题也要识别。
    // 误判成本很低：MarkdownPaster 解析不出内容会返回 false，回退输入法。
    return incoming.length >= 2 &&
        ((clipboardHtml?.trim().isNotEmpty ?? false) ||
            looksLikeMarkdown(incoming));
  }
  // 快照对不上（过期 / 输入法自带剪贴板）：保守一些，要求足够长。
  // 输入法的换行走 performAction，不会出现在 commitText 里；一次插入带换行
  // 基本只能是粘贴。Markdown 结构同理：逐字输入每次 delta 都很短。
  if (incoming.length < 20) {
    return false;
  }
  return looksLikeMarkdown(incoming) || incoming.contains('\n');
}

/// 两段文本是否等价（容忍输入法重排换行 / 空白）。
bool clipboardTextsMatch(String a, String b) {
  if (a == b || a.contains(b) || b.contains(a)) {
    return true;
  }
  final String aFlat = _withoutWhitespace(a);
  final String bFlat = _withoutWhitespace(b);
  if (aFlat.isEmpty || bFlat.isEmpty) {
    return false;
  }
  return aFlat == bFlat || aFlat.contains(bFlat) || bFlat.contains(aFlat);
}

String _withoutWhitespace(String value) => value.replaceAll(RegExp(r'\s+'), '');

/// 从剪贴板内容得到要解析的 Markdown；返回 null 表示按普通文本粘贴。
String? markdownFromClipboard({required String text, String? html}) {
  final String? rawHtml = html?.trim();
  if (rawHtml != null && rawHtml.isNotEmpty) {
    final String converted = htmlToMarkdown(rawHtml);
    if (converted.trim().isNotEmpty) {
      return converted;
    }
  }
  final String plain = text.trim();
  if (plain.isEmpty) {
    return null;
  }
  if (looksLikeMarkdown(plain)) {
    return normalizeRemoteImages(plain);
  }
  // Excel / 飞书 / 语雀表格复制成「纯文本」时只剩制表符分隔的行，
  // 这里按语雀「粘贴为表格」的规则自动还原成 GFM 表格。
  final String? table = tabSeparatedToMarkdown(plain);
  if (table != null) {
    return normalizeRemoteImages(table);
  }
  // 从微信 / 备忘录复制出来的纯文本，项目符号常是「•」「·」而不是
  // Markdown 的「-」。这种结构明确，直接归一化成列表再解析。
  final String? bullets = normalizePlainBullets(plain);
  return bullets == null ? null : normalizeRemoteImages(bullets);
}

/// 远程图片降级成普通链接。
///
/// 小记只渲染落盘的本地附件（`assets/<noteId>/…`）；从 GitHub / 网页
/// 复制过来的 `![](https://…)` 直接解析成图片块会得到一张坏图。转成
/// 链接既能保留信息，也不会破坏阅读。
String normalizeRemoteImages(String markdown) {
  return markdown.replaceAllMapped(
    RegExp(r'!\[([^\]\n]*)\]\(\s*((?:https?:)?//[^)\s]+)\s*\)'),
    (Match m) {
      final String alt = m.group(1)!.trim();
      final String url = m.group(2)!;
      return '[${alt.isEmpty ? url : alt}]($url)';
    },
  );
}

/// 制表符分隔文本 → GFM 管道表格；不像表格时返回 null。
///
/// 判定条件（与语雀「粘贴为表格」一致）：至少两行、至少两列、每行列数
/// 相同。首行当表头。正文里偶然出现的单个制表符不会命中，避免误判。
String? tabSeparatedToMarkdown(String text) {
  final List<String> lines = <String>[
    for (final String line in text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n'))
      if (line.trim().isNotEmpty) line,
  ];
  if (lines.length < 2) {
    return null;
  }
  final List<List<String>> rows = <List<String>>[
    for (final String line in lines) line.split('\t'),
  ];
  final int columns = rows.first.length;
  if (columns < 2) {
    return null;
  }
  if (rows.any((List<String> row) => row.length != columns)) {
    return null;
  }
  String cell(String value) => value.trim().replaceAll('|', r'\|');

  final StringBuffer buffer = StringBuffer(
    '| ${rows.first.map(cell).join(' | ')} |\n',
  );
  buffer.write('| ${List<String>.filled(columns, '---').join(' | ')} |');
  for (var r = 1; r < rows.length; r++) {
    buffer.write('\n| ${rows[r].map(cell).join(' | ')} |');
  }
  return buffer.toString();
}

/// 是否为 GFM 表格：某行是管道行，下一行是 `| --- |` 形态的分隔行。
bool _hasGfmTable(List<String> lines) {
  for (var i = 0; i + 1 < lines.length; i++) {
    final String header = lines[i].trim();
    if (!header.contains('|')) {
      continue;
    }
    if (!header.startsWith('|') && !header.endsWith('|')) {
      continue;
    }
    if (!_isGfmTableSeparator(lines[i + 1])) {
      continue;
    }
    final int cells = header
        .replaceAll(RegExp(r'^\||\|$'), '')
        .split('|')
        .length;
    if (cells >= 2) {
      return true;
    }
  }
  return false;
}

bool _isGfmTableSeparator(String line) {
  final String trimmed = line.trim();
  if (!trimmed.startsWith('|') && !trimmed.endsWith('|')) {
    return false;
  }
  // 只允许 | - : 与空白，且至少有一段连续 3 个以上的减号。
  return RegExp(r'^[|\s:-]+$').hasMatch(trimmed) &&
      RegExp(r'-{3,}').hasMatch(trimmed);
}

/// 把纯文本里的富文本项目符号（`• 项`、`· 项`）转成 Markdown 列表。
///
/// 至少两行才转换，避免把一句「• 重点」误判成列表。
String? normalizePlainBullets(String text) {
  final List<String> lines = text.split('\n');
  var bullets = 0;
  final List<String> converted = lines.map((String line) {
    // 中文输入法 / 微信复制常见全角空格缩进（U+3000），一并当作缩进。
    final Match? match =
        RegExp(r'^([ \t\u3000]*)[•·‣◦▪]\s+').firstMatch(line);
    if (match == null) {
      return line;
    }
    bullets++;
    final String indent = match.group(1)!.replaceAll('\u3000', '  ');
    return '$indent- ${line.substring(match.end)}';
  }).toList();
  if (bullets < 2) {
    return null;
  }
  return converted.join('\n');
}

/// 智能粘贴：把剪贴板里的 Markdown / HTML 解析成文档块后插入光标处。
///
/// 返回 true 表示已处理；false 由调用方回退到内核默认粘贴。
class MarkdownPaster {
  MarkdownPaster({
    required this.editor,
    required this.document,
    required this.composer,
    required this.ops,
    this.reader = const ClipboardReader(),
  });

  final Editor editor;
  final MutableDocument document;
  final MutableDocumentComposer composer;
  final CommonEditorOperations ops;
  final ClipboardReader reader;

  Future<bool> paste() async {
    final ClipboardContent content = await reader.read();
    return pasteContent(content);
  }

  /// 用已经读到的剪贴板内容同步粘贴。
  ///
  /// 键盘（IME）粘贴必须在同一次 delta 回调里同步完成：如果先 return、
  /// 稍后再异步落库，系统输入法仍按「已经粘贴成功」的文本继续上报位置，
  /// 会和文档结构错位（实测报 No such document position）。
  bool pasteContent(ClipboardContent content) {
    final DocumentSelection? selection = composer.selection;
    if (selection == null) {
      return false;
    }
    // 跨块选区交给内核默认粘贴：拆分会破坏列表 / 任务项的结构。
    if (selection.base.nodeId != selection.extent.nodeId) {
      return false;
    }
    final DocumentNode? node = document.getNodeById(selection.extent.nodeId);
    if (node is! TextNode) {
      return false;
    }

    final String? markdown = markdownFromClipboard(
      text: content.text,
      html: content.html,
    );
    if (markdown == null) {
      return false;
    }

    final List<DocumentNode> pasted = _parseNodes(markdown);
    if (pasted.isEmpty) {
      return false;
    }

    final NodePosition base = selection.base.nodePosition;
    final NodePosition extent = selection.extent.nodePosition;
    if (base is! TextNodePosition || extent is! TextNodePosition) {
      return false;
    }
    final int start = math.min(base.offset, extent.offset);
    final int end = math.max(base.offset, extent.offset);
    final int maxOffset = node.text.toPlainText().length;
    if (start > maxOffset || end > maxOffset) {
      return false;
    }

    try {
      _insert(
        node: node,
        before: node.text.copyText(0, start),
        after: node.text.copyText(end),
        pasted: pasted,
      );
      return true;
    } catch (error, stack) {
      debugPrint('Markdown 粘贴失败，回退默认粘贴: $error\n$stack');
      return false;
    }
  }

  /// 解析 Markdown，并整理空段落。
  ///
  /// 空段落不能全部丢掉：粘贴「第一段 / 空行 / 第二段」时，两个段落节点
  /// 之间如果没有空段落，序列化会写成相邻两行，下次解析就合并成**一个**
  /// 段落（行内换行），段落间距永久丢失。这里只在「普通段落 → 普通段落」
  /// 之间保留一个空段落，其余位置与首尾一律去掉 —— 既保住段落分隔，
  /// 也不多出空白。
  List<DocumentNode> _parseNodes(String markdown) {
    final MutableDocument parsed = deserializeXiaojiMarkdown(markdown);
    bool isBlankParagraph(DocumentNode node) =>
        node is ParagraphNode &&
        node.text.toPlainText().trim().isEmpty &&
        _isPlainParagraph(node);

    final List<DocumentNode> all = <DocumentNode>[
      for (int i = 0; i < parsed.nodeCount; i++) parsed.getNodeAt(i)!,
    ];
    final List<DocumentNode> nodes = <DocumentNode>[];
    for (int i = 0; i < all.length; i++) {
      final DocumentNode node = all[i];
      if (!isBlankParagraph(node)) {
        nodes.add(node);
        continue;
      }
      // 开头的空段落不要。
      if (nodes.isEmpty) {
        continue;
      }
      // 找下一个非空块；结尾的空段落不要。
      DocumentNode? next;
      for (int j = i + 1; j < all.length; j++) {
        if (!isBlankParagraph(all[j])) {
          next = all[j];
          break;
        }
      }
      if (next == null) {
        continue;
      }
      // 只有「普通段落 → 普通段落」才必须留空行，否则下次解析会把两段
      // 合并成一个段落。标题/列表/代码等块之间不需要，留了反而多出空白。
      final DocumentNode prev = nodes.last;
      final bool needsBlank = prev is ParagraphNode &&
          _isPlainParagraph(prev) &&
          next is ParagraphNode &&
          _isPlainParagraph(next);
      if (needsBlank && !isBlankParagraph(nodes.last)) {
        nodes.add(node);
      }
    }
    return nodes;
  }

  bool _isPlainParagraph(ParagraphNode node) {
    final Object? blockType = node.metadata[NodeMetadata.blockType];
    return blockType == null || blockType == paragraphAttribution;
  }

  void _insert({
    required TextNode node,
    required AttributedText before,
    required AttributedText after,
    required List<DocumentNode> pasted,
  }) {
    // 输入法可能还留着旧的组合区（拼音 / 联想），并指向粘贴前的段落。
    // 粘贴后选区落到新块，组合区和选区不在同一节点，super_editor 序列化
    // IME 内容时会抛 “No such document position in the IME content”，
    // 之后打字整体失效。粘贴前先清掉组合区。
    composer.setComposingRegion(null);

    final DocumentNode first = pasted.first;
    // 单个普通段落：并入当前段落，保留前后文与行内样式。
    // 解析器可能给段落带上 `blockType: paragraph`，按 blockType 判断而不是
    // metadata 是否为空。
    if (pasted.length == 1 &&
        first is ParagraphNode &&
        _isPlainParagraph(first)) {
      final AttributedText merged = before
          .copyAndAppend(first.text)
          .copyAndAppend(after);
      final int caret =
          before.toPlainText().length + first.text.toPlainText().length;
      editor.execute(<EditRequest>[
        ReplaceNodeRequest(
          existingNodeId: node.id,
          newNode: node.copyTextNodeWith(text: merged),
        ),
        ChangeSelectionRequest(
          DocumentSelection.collapsed(
            position: DocumentPosition(
              nodeId: node.id,
              nodePosition: TextNodePosition(offset: caret),
            ),
          ),
          SelectionChangeType.insertContent,
          SelectionReason.userInteraction,
        ),
      ]);
      return;
    }

    final int index = document.getNodeIndexById(node.id);
    final List<EditRequest> requests = <EditRequest>[];
    DocumentNode? lastInserted;
    int insertAt = index + 1;

    /// 普通段落之间需要空段落分隔，否则存盘重读会被合并成一段。
    ParagraphNode separator() => ParagraphNode(
          id: Editor.createNodeId(),
          text: AttributedText(),
        );

    if (before.toPlainText().isEmpty) {
      // 当前块会被完全替换成第一个粘贴块，不留空段落。
      requests.add(ReplaceNodeRequest(existingNodeId: node.id, newNode: first));
      lastInserted = first;
      for (final DocumentNode pastedNode in pasted.skip(1)) {
        requests.add(
          InsertNodeAtIndexRequest(nodeIndex: insertAt++, newNode: pastedNode),
        );
        lastInserted = pastedNode;
      }
    } else {
      // 光标在段落中间：保留前半段，粘贴块接在它后面。
      requests.add(
        ReplaceNodeRequest(
          existingNodeId: node.id,
          newNode: node.copyTextNodeWith(text: before),
        ),
      );
      // 前半段是普通段落、粘贴块也以普通段落开头时，中间补一个空段落，
      // 否则「前半段 + 粘贴首段」存盘后会被解析成一个段落。
      if (first is ParagraphNode && _isPlainParagraph(first)) {
        requests.add(
          InsertNodeAtIndexRequest(
            nodeIndex: insertAt++,
            newNode: separator(),
          ),
        );
      }
      for (final DocumentNode pastedNode in pasted) {
        requests.add(
          InsertNodeAtIndexRequest(nodeIndex: insertAt++, newNode: pastedNode),
        );
        lastInserted = pastedNode;
      }
    }

    late final DocumentNode caretNode;
    late final int caretOffset;
    if (after.toPlainText().isNotEmpty) {
      // 光标后的残余文字另起一段；它和粘贴块之间同样需要空段落。
      if (lastInserted is ParagraphNode && _isPlainParagraph(lastInserted)) {
        requests.add(
          InsertNodeAtIndexRequest(
            nodeIndex: insertAt++,
            newNode: separator(),
          ),
        );
      }
      final ParagraphNode tail =
          ParagraphNode(id: Editor.createNodeId(), text: after);
      requests.add(
        InsertNodeAtIndexRequest(nodeIndex: insertAt, newNode: tail),
      );
      caretNode = tail;
      caretOffset = 0;
    } else if (lastInserted is TextNode) {
      caretNode = lastInserted;
      caretOffset = lastInserted.text.toPlainText().length;
    } else {
      // 粘贴内容以图片 / 分隔线结尾时，垫一个空段落接住光标。
      final ParagraphNode tail = ParagraphNode(
        id: Editor.createNodeId(),
        text: AttributedText(),
      );
      requests.add(
        InsertNodeAtIndexRequest(nodeIndex: insertAt, newNode: tail),
      );
      caretNode = tail;
      caretOffset = 0;
    }

    requests.add(
      ChangeSelectionRequest(
        DocumentSelection.collapsed(
          position: DocumentPosition(
            nodeId: caretNode.id,
            nodePosition: TextNodePosition(offset: caretOffset),
          ),
        ),
        SelectionChangeType.insertContent,
        SelectionReason.userInteraction,
      ),
    );
    editor.execute(requests);
  }
}
