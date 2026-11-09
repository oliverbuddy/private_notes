import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';
import 'package:xiaoji/editor/lab/editor_request_handlers.dart';
import 'package:xiaoji/editor/lab/xiaoji_markdown.dart';

/// 代码块编辑语义：围栏内回车只能插入字面换行，不能拆成两个代码块。
///
/// 内核默认的 `DefaultInsertNewlineAtCaretCommand` 会把段落一分为二，
/// 新节点复制 blockType=code —— 序列化时每个代码节点各写一对围栏，
/// 用户回一次车就多出一对 ```（看起来像代码块被截断）。
void main() {
  late MutableDocument document;
  late MutableDocumentComposer composer;
  late Editor editor;

  setUp(() {
    document = deserializeXiaojiMarkdown('```dart\nvoid main() {}\n```');
    composer = MutableDocumentComposer();
    editor = createXiaojiEditor(document: document, composer: composer);
  });

  test('代码块内回车：保持单节点，只插入字面换行', () {
    final DocumentNode node = document.getNodeAt(0)!;
    expect(node, isA<ParagraphNode>());
    final ParagraphNode code = node as ParagraphNode;
    expect(
      code.getMetadataValue(NodeMetadata.blockType),
      codeAttribution,
    );
    final int end = code.text.length;

    composer.setSelectionWithReason(
      DocumentSelection.collapsed(
        position: DocumentPosition(
          nodeId: code.id,
          nodePosition: TextNodePosition(offset: end),
        ),
      ),
    );
    editor.execute(<EditRequest>[InsertNewlineAtCaretRequest()]);

    // 代码块仍是唯一的代码节点，回车只多一个换行字符。
    final List<ParagraphNode> codeNodes = document
        .whereType<ParagraphNode>()
        .where((ParagraphNode n) =>
            n.getMetadataValue(NodeMetadata.blockType) == codeAttribution)
        .toList();
    expect(codeNodes, hasLength(1),
        reason: '围栏内回车不能把代码块拆成两个节点');
    // 解析阶段已去掉合成换行，回车只多出用户敲的那一个 `\n`。
    expect(codeNodes.single.text.toPlainText(), 'void main() {}\n');

    // 往返回合只产出一对围栏，且用户敲出的空行不会丢。
    final String md = serializeDocumentToXiaojiMarkdown(document);
    expect('```'.allMatches(md).length, 2, reason: '回一次车不能多出一对围栏');
    expect(md, '```dart\nvoid main() {}\n\n```');
  });
}
