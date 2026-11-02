import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/block.dart';
import 'package:xiaoji/models/note.dart';

void main() {
  group('块解析与序列化', () {
    test('纯文本往返无损', () {
      const markdown = '第一行\n第二行\n\n第四行';
      expect(serializeBlocks(parseBlocks(markdown)), markdown);
    });

    test('空正文往返无损', () {
      expect(serializeBlocks(parseBlocks('')), '');
    });

    test('末尾换行保持原样', () {
      const markdown = 'abc\n';
      expect(serializeBlocks(parseBlocks(markdown)), markdown);
    });

    test('连续空行不被吞掉', () {
      const markdown = 'a\n\n\nb';
      expect(serializeBlocks(parseBlocks(markdown)), markdown);
    });

    test('图片独占一行时成为图片块', () {
      const markdown = '看看这个\n![](assets/n1/1.jpg)\n不错';
      final blocks = parseBlocks(markdown);
      expect(blocks.length, 3);
      expect(blocks[1], isA<ImageBlock>());
      expect((blocks[1] as ImageBlock).path, 'assets/n1/1.jpg');
      expect(serializeBlocks(blocks), markdown);
    });

    test('附件独占一行时成为文件块', () {
      const markdown = '[报告.pdf](assets/n1/1.pdf)';
      final blocks = parseBlocks(markdown);
      expect(blocks.length, 1);
      expect(blocks.first, isA<FileBlock>());
      expect(serializeBlocks(blocks), markdown);
    });

    test('外链不当作附件块', () {
      const markdown = '[官网](https://example.com)';
      final blocks = parseBlocks(markdown);
      expect(blocks.first, isA<TextBlock>());
      expect(serializeBlocks(blocks), markdown);
    });

    test('缩进的图片语法仍按文本处理（保证无损）', () {
      const markdown = '  ![](assets/n1/1.jpg)';
      final blocks = parseBlocks(markdown);
      expect(blocks.first, isA<TextBlock>());
      expect(serializeBlocks(blocks), markdown);
    });

    test('多块混合往返无损', () {
      const markdown = '# 标题\n\n正文 **粗体**\n![](assets/n1/1.jpg)\n'
          '[a.pdf](assets/n1/a.pdf)\n\n- [ ] 待办\n- [x] 已完成';
      expect(serializeBlocks(parseBlocks(markdown)), markdown);
    });

    test('末尾用于输入的占位空块不写进文件', () {
      final blocks = parseBlocks('hello');
      blocks.add(TextBlock(''));
      expect(serializeBlocks(blocks), 'hello');
    });

    test('只有空块时序列化为空串', () {
      expect(serializeBlocks(<Block>[TextBlock('')]), '');
    });
  });

  group('纯文本摘要', () {
    test('剥掉常见 markdown 记号', () {
      const markdown = '# 标题\n\n**加粗** 和 `代码`\n- [ ] 待办\n> 引用\n'
          '[链接](https://example.com)';
      final plain = plainSummary(markdown);
      expect(plain, contains('标题'));
      expect(plain, isNot(contains('#')));
      expect(plain, isNot(contains('**')));
      expect(plain, isNot(contains('`')));
      expect(plain, isNot(contains('https://')));
      expect(plain, contains('链接'));
    });

    test('图片行不进入摘要，附件降级为文件名', () {
      const markdown = '![](assets/n1/1.jpg)\n[报告.pdf](assets/n1/1.pdf)';
      final plain = plainSummary(markdown);
      expect(plain, isNot(contains('![')));
      expect(plain, contains('报告.pdf'));
    });

    test('空正文得到空摘要', () {
      expect(plainSummary('   '), '');
    });
  });

  group('Note frontmatter', () {
    test('编码后能原样解回', () {
      final note = Note(
        id: '20261031-0912-a1b2',
        created: DateTime(2026, 10, 31, 9, 12, 33),
        updated: DateTime(2026, 10, 31, 9, 15, 10),
        tags: const <String>['旅行', '想法'],
        pinned: true,
        body: '正文 markdown',
      );
      final decoded = Note.decode(note.encode());
      expect(decoded, isNotNull);
      expect(decoded!.id, note.id);
      expect(decoded.created, note.created);
      expect(decoded.updated, note.updated);
      expect(decoded.tags, note.tags);
      expect(decoded.pinned, isTrue);
      expect(decoded.body, note.body);
    });

    test('没有 frontmatter 的内容解析失败而不是抛异常', () {
      expect(Note.decode('随便一段没有 frontmatter 的文本'), isNull);
    });

    test('标签解析兼容中文逗号', () {
      expect(Note.parseTags('旅行，想法, 待办'), <String>['旅行', '想法', '待办']);
    });

    test('缺少 id 时用文件名兜底', () {
      const raw = '---\ntags: a\n---\n\n正文';
      final decoded = Note.decode(raw, fallbackId: '20260101-0000-0000');
      expect(decoded, isNotNull);
      expect(decoded!.id, '20260101-0000-0000');
    });
  });
}
