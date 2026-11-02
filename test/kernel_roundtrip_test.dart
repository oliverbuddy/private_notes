import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';
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
}
