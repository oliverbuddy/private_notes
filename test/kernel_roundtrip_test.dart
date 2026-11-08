import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';
import 'package:xiaoji/editor/lab/image_display_size.dart';
import 'package:xiaoji/editor/lab/xiaoji_markdown.dart';

/// M1 安全底线：md 解析 → 文档 → 小记序列化器 必须幂等且不丢内容。
/// 编辑器怎么改排版都行，用户数据一个字都不能动。
void main() {
  const sample = '''# 标题一

**加粗**、*斜体*、`行内码`，还有一段中文正文。

1. 有序一
2. 有序二
   1. 嵌套子项
- 无序一项
- 无序二项

- [ ] 待办未完成
- [x] 待办已完成
> 这是一行引用

---

收尾段落。''';

  String roundTrip(String md) {
    final doc = deserializeXiaojiMarkdown(md);
    return serializeDocumentToXiaojiMarkdown(doc);
  }

  test('围栏代码块的语言标记往返保留', () {
    const String body = '```dart\nvoid main() { print(1); }\n```';
    final doc = deserializeXiaojiMarkdown(body);
    final String out = serializeDocumentToXiaojiMarkdown(doc);
    expect(out, contains('```dart'));
    expect(out, contains('void main() { print(1); }'));
  });

  test('代码内容含 ``` 时围栏自动加长，不会被提前闭合', () {
    const String body = '````\n```\n片段\n```\n````';
    final doc = deserializeXiaojiMarkdown(body);
    final String out = serializeDocumentToXiaojiMarkdown(doc);
    expect(out.split('\n').first, '````');
    expect(out, contains('片段'));
  });

  test('==高亮== 解析成属性，标记字符从正文里移除', () {
    final doc = deserializeXiaojiMarkdown('这是 ==重点== 内容');
    final node = doc.getNodeAt(0)! as ParagraphNode;
    expect(node.text.toPlainText(), '这是 重点 内容');
    expect(
      node.text.spans.getAllAttributionsAt(3).contains(highlightAttribution),
      isTrue,
    );
    expect(
      node.text.spans.getAllAttributionsAt(0).contains(highlightAttribution),
      isFalse,
    );
  });

  test('==高亮== 序列化回标记，且往返幂等', () {
    final String out = roundTrip('这是 ==重点== 内容');
    expect(out, contains('==重点=='));
    expect(roundTrip(out), out);
  });

  test('高亮与粗体叠加时两种属性都保留', () {
    final doc = deserializeXiaojiMarkdown('**==重点==**');
    final node = doc.getNodeAt(0)! as ParagraphNode;
    expect(node.text.toPlainText(), '重点');
    final Set<Attribution> attrs = node.text.spans.getAllAttributionsAt(0);
    expect(attrs.contains(highlightAttribution), isTrue);
    expect(attrs.contains(boldAttribution), isTrue);
    final String out = serializeDocumentToXiaojiMarkdown(doc);
    expect(out, contains('==重点=='));
    expect(out, contains('**'));
  });

  test('代码块里的 == 不当高亮语法', () {
    final doc = deserializeXiaojiMarkdown('```\na == b\n```');
    final String out = serializeDocumentToXiaojiMarkdown(doc);
    expect(out, contains('a == b'));
    expect(out, isNot(contains('==a')));
  });

  test('表格单元格里的 ==高亮== 同样生效', () {
    final doc = deserializeXiaojiMarkdown(
      '| 名称 | 说明 |\n| --- | --- |\n| 甲 | ==重点== |',
    );
    final table = doc.getNodeAt(0)! as TableBlockNode;
    expect(table.getCell(rowIndex: 1, columnIndex: 1).text.toPlainText(), '重点');
    expect(
      serializeDocumentToXiaojiMarkdown(doc),
      contains('| 甲 | ==重点== |'),
    );
  });

  test('嵌套待办独立成节点，缩进与勾选状态都保留', () {
    const String body = '- [ ] 父\n  - [x] 子';
    final doc = deserializeXiaojiMarkdown(body);
    final List<TaskNode> tasks = doc.whereType<TaskNode>().toList();
    expect(tasks, hasLength(2));
    expect(tasks[0].text.toPlainText(), '父');
    expect(tasks[0].indent, 0);
    expect(tasks[1].text.toPlainText(), '子');
    expect(tasks[1].indent, 1);
    expect(tasks[1].isComplete, isTrue);

    final String out = serializeDocumentToXiaojiMarkdown(doc);
    expect(out, contains('- [ ] 父'));
    expect(out, contains('  - [x] 子'));
  });

  test('待办下的无序子项不会被并进父项文本', () {
    const String body = '- [ ] 父\n  - 子项';
    final doc = deserializeXiaojiMarkdown(body);
    expect(doc.whereType<TaskNode>().length, 1);
    final ListItemNode child = doc.whereType<ListItemNode>().single;
    expect(child.text.toPlainText(), '子项');
    expect(child.indent, 1);
    expect(
      serializeDocumentToXiaojiMarkdown(doc),
      contains('  - 子项'),
    );
  });

  test('嵌套引用保留换行，不会把两层文字拼在一起', () {
    const String body = '> 外层\n> > 内层';
    final doc = deserializeXiaojiMarkdown(body);
    final ParagraphNode quote = doc.getNodeAt(0)! as ParagraphNode;
    expect(quote.text.toPlainText(), '外层\n内层');
    expect(
      serializeDocumentToXiaojiMarkdown(doc),
      contains('> 外层\n> 内层'),
    );
  });

  test('缩进代码块不在结尾多出空行，往返幂等', () {
    const String body = '    code line\n    second';
    final String once = roundTrip(body);
    expect(once, '```\ncode line\nsecond\n```');
    expect(roundTrip(once), once);
  });

  test('setext 标题转成 ATX，不会把 === / --- 留在正文里', () {
    final ParagraphNode h1 =
        deserializeXiaojiMarkdown('标题\n===').getNodeAt(0)! as ParagraphNode;
    expect(
      h1.getMetadataValue(NodeMetadata.blockType),
      header1Attribution,
    );
    final ParagraphNode h2 =
        deserializeXiaojiMarkdown('标题\n---').getNodeAt(0)! as ParagraphNode;
    expect(
      h2.getMetadataValue(NodeMetadata.blockType),
      header2Attribution,
    );
  });

  test('转义输入的语法字符写回时仍保持字面量', () {
    const String body = r'不是\*斜体\*';
    final doc = deserializeXiaojiMarkdown(body);
    final ParagraphNode node = doc.getNodeAt(0)! as ParagraphNode;
    expect(node.text.toPlainText(), '不是*斜体*');
    expect(
      node.text.spans.hasAttributionAt(2, attribution: italicsAttribution),
      isFalse,
    );
    expect(serializeDocumentToXiaojiMarkdown(doc), contains(r'\*斜体\*'));
  });

  test('行内码自带反引号时用更长的围栏，往返不破坏', () {
    const String body = '``a `b` c``';
    final String once = roundTrip(body);
    expect(once, '``a `b` c``');
    expect(roundTrip(once), once);
  });

  test('有序列表起始编号保留，后续编号顺延', () {
    const String body = '5. 第五\n6. 第六\n7. 第七';
    final String out = roundTrip(body);
    expect(out, '5. 第五\n6. 第六\n7. 第七');
    expect(roundTrip(out), out);
  });

  test('嵌套有序列表各自保留自己的起始编号', () {
    const String body = '3. 外层\n   1. 内层一\n   2. 内层二';
    final String out = roundTrip(body);
    expect(out, contains('3. 外层'));
    expect(out, contains('1. 内层一'));
    expect(out, contains('2. 内层二'));
  });

  test('有序项显示编号 = 起始编号 + 层内序号 - 1', () {
    final doc = deserializeXiaojiMarkdown('5. 甲\n6. 乙');
    final List<ListItemNode> items = doc.whereType<ListItemNode>().toList();
    final ({int ordinal, int start}) first =
        orderedListItemNumber(doc, items[0])!;
    final ({int ordinal, int start}) second =
        orderedListItemNumber(doc, items[1])!;
    expect(first.start + first.ordinal - 1, 5);
    expect(second.start + second.ordinal - 1, 6);
  });

  test('链接 title 并入链接属性，往返保留', () {
    const String body = '[文字](https://example.com "标题")';
    final doc = deserializeXiaojiMarkdown(body);
    final ParagraphNode node = doc.getNodeAt(0)! as ParagraphNode;
    final LinkAttribution link = node.text.spans
        .getAllAttributionsAt(0)
        .whereType<LinkAttribution>()
        .first;
    expect(link, isA<XiaojiLinkAttribution>());
    expect((link as XiaojiLinkAttribution).title, '标题');
    expect(
      serializeDocumentToXiaojiMarkdown(doc),
      contains('[文字](https://example.com "标题")'),
    );
  });

  test('单引号 / 括号形式的链接 title 也归一化成双引号', () {
    expect(
      roundTrip("[文字](https://a.com '标题')"),
      contains('[文字](https://a.com "标题")'),
    );
    expect(
      roundTrip('[文字](https://b.com (标题))'),
      contains('[文字](https://b.com "标题")'),
    );
  });

  test('没有 title 的链接保持原样', () {
    expect(
      roundTrip('[文字](https://example.com)'),
      contains('[文字](https://example.com)'),
    );
  });

  test('待办后紧跟图片：图片仍是独立 ImageNode', () {
    const String body = '- [ ] read book\n![](assets/n/1.jpg#xiaoji-small)';
    final doc = deserializeXiaojiMarkdown(body);
    final List<String> types =
        doc.map((DocumentNode n) => n.runtimeType.toString()).toList();
    expect(
      doc.any((DocumentNode n) => n is ImageNode),
      isTrue,
      reason: '节点类型：$types',
    );
    // 解析时补的隔断空行不能写回存储（否则每次打开都多一行）。
    expect(serializeDocumentToXiaojiMarkdown(doc), body);
  });

  test('正文段落紧跟图片：图片仍是独立 ImageNode', () {
    const String body = '超长图\n![](assets/n/1.jpg#xiaoji-small)';
    final doc = deserializeXiaojiMarkdown(body);
    final List<String> types =
        doc.map((DocumentNode n) => n.runtimeType.toString()).toList();
    expect(
      doc.any((DocumentNode n) => n is ImageNode),
      isTrue,
      reason: '节点类型：$types',
    );
    expect(serializeDocumentToXiaojiMarkdown(doc), body);
  });

  test('图片小图标记往返保持，且能还原真实路径', () {
    final doc = deserializeXiaojiMarkdown('![](assets/n/1.jpg#xiaoji-small)');
    final ImageNode image =
        doc.firstWhere((DocumentNode n) => n is ImageNode) as ImageNode;

    expect(image.imageUrl, 'assets/n/1.jpg#xiaoji-small');
    expect(imageDisplaySizeOf(image.imageUrl), ImageDisplaySize.small);
    expect(imageFilePath(image.imageUrl), 'assets/n/1.jpg');

    final out = serializeDocumentToXiaojiMarkdown(doc);
    expect(out, contains('#xiaoji-small'));

    // 大图：去掉标记后是干净路径。
    expect(
      imageUrlWithSize(image.imageUrl, ImageDisplaySize.large),
      'assets/n/1.jpg',
    );
  });

  test('解析→序列化幂等：第二次往返不再改变内容', () {
    final out1 = roundTrip(sample);
    final out2 = roundTrip(out1);

    expect(out2, out1, reason: '第二次保存不应改变内容（幂等）');
  });

  test('关键内容全部保留', () {
    final out = roundTrip(sample);

    expect(out, contains('# 标题一'));
    expect(out, contains('**加粗**'));
    expect(out, contains('*斜体*'));
    expect(out, contains('中文正文'));
    expect(out, contains('1. 有序一'));
    expect(out, contains('2. 有序二'));
    expect(out, contains('1. 嵌套子项'));
    expect(out, contains('- 无序一项'));
    expect(out, contains('- [ ] 待办未完成'));
    expect(out, contains('- [x] 待办已完成'));
    expect(out, contains('> 这是一行引用'));
    expect(out, contains('---'));
    expect(out, contains('收尾段落'));
  });

  test('有序列表编号同层连续，嵌套子层从 1 重新计', () {
    final out = roundTrip('1. 甲\n2. 乙\n   1. 子\n2. 丙');
    expect(out, contains('1. 甲'));
    expect(out, contains('2. 乙'));
    expect(out, contains('1. 子'));
    expect(out, contains('3. 丙'), reason: '弹回父级后编号接续');
  });

  test('待办状态在往返中保持', () {
    final out = roundTrip('- [ ] 甲\n- [x] 乙');
    expect(out, contains('- [ ] 甲'));
    expect(out, contains('- [x] 乙'));
  });

  test('代码块内容不丢', () {
    final out = roundTrip('```void main() {}\nprint(1);\n```');
    expect(out, contains('print(1);'));
  });

  test('多行引用逐行带 "> " 前缀（按行解析不会被拆成普通段落）', () {
    final out = roundTrip('> 引用第一行\n> 引用第二行');
    expect(out, contains('> 引用第一行'));
    expect(out, contains('> 引用第二行'));
    expect(
      out
          .split('\n')
          .every((String line) => !line.contains('引用') || line.startsWith('> ')),
      isTrue,
      reason: '引用行必须都带前缀，否则列表摘要会把后续行当普通段落',
    );
  });

  test('任务行后紧跟的段落被拆回独立块（黏连修复）', () {
    final doc = deserializeXiaojiMarkdown('- [ ] 待办\n紧跟段落');
    expect(doc.whereType<TaskNode>().length, 1, reason: '任务只有首行');
    final task = doc.whereType<TaskNode>().first;
    expect(task.text.toPlainText(), '待办');
    expect(
      serializeDocumentToXiaojiMarkdown(doc),
      contains('紧跟段落'),
      reason: '段落内容保留',
    );
  });

  test('空行哨兵绝不写进存储（列表/图片/引用后空行）', () {
    const List<String> samples = <String>[
      '> a\n> b\n\n文字',
      '- 一\n\n正文',
      '- [ ] 甲\n\n- [x] 乙',
      '![](assets/n/1.jpg)\n\n文字',
      '正文\n\n下一段',
      '# 标题\n\n正文',
    ];
    for (final sample in samples) {
      final String out = roundTrip(sample);
      expect(
        out.contains('\uE000'),
        isFalse,
        reason: '样本「$sample」把解析期哨兵写进了存储（摘要会显示成 ☒ 乱码）',
      );
    }
    // 列表旁边的空行不按「空段落」处理：它属于列表的松散结构，按行解析
    // 会把层级带歪；但文字不能丢、也绝不能把哨兵写进存储。
    final String listOut = roundTrip('- 一\n\n正文');
    expect(listOut, contains('一'));
    expect(listOut, contains('正文'));
  });

  test('附件行独占一段，往返不丢（卡片才能被识别）', () {
    const md = '正文\n[报告.pdf](assets/n1/a.pdf)\n![](assets/n1/1.jpg)';
    final doc = deserializeXiaojiMarkdown(md);
    // 末尾始终补一个空段落（编辑期底部可落的空白），不算正文段落。
    final paragraphs = doc
        .whereType<ParagraphNode>()
        .where((ParagraphNode node) => node.text.isNotEmpty)
        .toList();
    expect(paragraphs.length, 2, reason: '正文与附件行必须拆成两个段落');
    final attachment = paragraphs.last;
    expect(attachment.text.toPlainText(), '报告.pdf');
    final link = attachment.text.spans
        .getAllAttributionsAt(0)
        .whereType<LinkAttribution>()
        .single;
    expect(link.plainTextUri, 'assets/n1/a.pdf');

    final out = serializeDocumentToXiaojiMarkdown(doc);
    expect(out, contains('正文'));
    expect(out, contains('[报告.pdf](assets/n1/a.pdf)'));
    expect(out, contains('![](assets/n1/1.jpg)'));
  });

  test('表格：解析成表节点，序列化保持行列与表头', () {
    const String body = '| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |';
    final doc = deserializeXiaojiMarkdown(body);
    expect(
      doc.any((DocumentNode node) => node is TableBlockNode),
      isTrue,
      reason: '节点类型：${doc.map((DocumentNode n) => n.runtimeType).toList()}',
    );
    expect(serializeDocumentToXiaojiMarkdown(doc), body);
  });

  test('表格：紧跟在段落后面（无空行）仍能识别并原样保存', () {
    const String body = '前文\n| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |';
    final doc = deserializeXiaojiMarkdown(body);
    expect(
      doc.any((DocumentNode node) => node is TableBlockNode),
      isTrue,
      reason: '节点类型：${doc.map((DocumentNode n) => n.runtimeType).toList()}',
    );
    expect(serializeDocumentToXiaojiMarkdown(doc), body);
  });

  test('表格：单元格内的行内样式往返不丢', () {
    const String body = '| 名称 | 说明 |\n| --- | --- |\n| 苹果 | **甜** |';
    final doc = deserializeXiaojiMarkdown(body);
    expect(serializeDocumentToXiaojiMarkdown(doc), body);
  });
}
