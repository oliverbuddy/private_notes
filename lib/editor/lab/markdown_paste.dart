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
/// 判定刻意保守：至少两处块级标记，或出现链接 / 图片 / 加粗 / 行内码。
/// 普通聊天记录（只有一行以「-」开头）仍按纯文本粘贴，不会被拆成列表。
bool looksLikeMarkdown(String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) {
    return false;
  }
  final List<String> lines = trimmed.split('\n');
  int markers = 0;
  bool inFence = false;
  for (final String line in lines) {
    final String left = line.trimLeft();
    if (left.startsWith('```')) {
      inFence = !inFence;
      // 代码围栏本身就是强信号，单行也按 Markdown 处理。
      return true;
    }
    if (inFence) {
      continue;
    }
    // 标题是强信号：`## 小节` 单独出现也应当解析。
    if (RegExp(r'^#{1,6}\s').hasMatch(left)) {
      return true;
    }
    if (RegExp(r'^>\s').hasMatch(left) ||
        RegExp(r'^([-*+])\s').hasMatch(left) ||
        RegExp(r'^\d+[.)]\s').hasMatch(left)) {
      markers++;
    }
  }
  if (markers >= 2) {
    return true;
  }
  return RegExp(r'!\[[^\]]*\]\([^)]+\)').hasMatch(trimmed) ||
      RegExp(r'\[[^\]]+\]\([^)]+\)').hasMatch(trimmed) ||
      RegExp(r'\*\*[^*\n]+\*\*').hasMatch(trimmed) ||
      RegExp(r'`[^`\n]+`').hasMatch(trimmed);
}

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
  return looksLikeMarkdown(plain) ? plain : null;
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

    final ClipboardContent content = await reader.read();
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

  /// 解析 Markdown，并去掉空行产生的哨兵空段落。
  ///
  /// 小记的存储格式不保留空行，空段落只会让粘贴结果多出空白；
  /// 解析器还会在末尾补一个可编辑的哨兵段落，一并丢掉。
  List<DocumentNode> _parseNodes(String markdown) {
    final MutableDocument parsed = deserializeXiaojiMarkdown(markdown);
    final List<DocumentNode> nodes = <DocumentNode>[
      for (int i = 0; i < parsed.nodeCount; i++) parsed.getNodeAt(i)!,
    ];
    nodes.removeWhere(
      (DocumentNode node) =>
          node is ParagraphNode &&
          node.text.toPlainText().trim().isEmpty &&
          _isPlainParagraph(node),
    );
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
