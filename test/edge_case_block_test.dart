import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/block.dart';

/// 块解析 / 序列化的边界补充测试。
///
/// 只验证一条硬约束：`serialize(parse(md)) == md`，以及「什么算块」的边界。
void main() {
  group('边界：空正文与纯空白', () {
    test('空字符串解析出唯一一个空文本块', () {
      final blocks = parseBlocks('');
      expect(blocks.length, 1);
      expect(blocks.single, isA<TextBlock>());
      expect((blocks.single as TextBlock).text, '');
    });

    test('空字符串往返仍是空字符串', () {
      expect(serializeBlocks(parseBlocks('')), '');
    });

    test('纯空白字符正文往返无损', () {
      const markdown = '   \n\t\n  ';
      expect(serializeBlocks(parseBlocks(markdown)), markdown);
    });

    test('纯空白正文不会被误判成图片块', () {
      final blocks = parseBlocks(' \n ');
      expect(blocks.length, 1);
      expect(blocks.single, isA<TextBlock>());
    });

    test('只有一个换行的正文往返无损', () {
      const markdown = '\n';
      final blocks = parseBlocks(markdown);
      expect(serializeBlocks(blocks), markdown);
    });
  });

  group('边界：图片块', () {
    test('只有一张图片、没有文本时只有一个图片块', () {
      const markdown = '![](assets/n1/1.jpg)';
      final blocks = parseBlocks(markdown);
      expect(blocks.length, 1);
      expect(blocks.single, isA<ImageBlock>());
      expect((blocks.single as ImageBlock).path, 'assets/n1/1.jpg');
      expect(serializeBlocks(blocks), markdown);
    });

    test('只有图片时末尾输入占位空块不写进文件', () {
      final blocks = parseBlocks('![](assets/n1/1.jpg)');
      blocks.add(TextBlock());
      expect(serializeBlocks(blocks), '![](assets/n1/1.jpg)');
    });

    test('连续多张图片各自成为独立图片块', () {
      const markdown = '![](assets/n1/1.jpg)\n'
          '![](assets/n1/2.jpg)\n'
          '![](assets/n1/3.jpg)';
      final blocks = parseBlocks(markdown);
      expect(blocks.length, 3);
      expect(blocks.every((block) => block is ImageBlock), isTrue);
      expect(serializeBlocks(blocks), markdown);
    });

    test('图片前后各有空行时块边界正确且往返无损', () {
      const markdown = '前文\n\n![](assets/n1/1.jpg)\n\n后文';
      final blocks = parseBlocks(markdown);
      expect(blocks.length, 3);
      expect((blocks[0] as TextBlock).text, '前文\n');
      expect((blocks[2] as TextBlock).text, '\n后文');
      expect(serializeBlocks(blocks), markdown);
    });

    test('中间的空文本块不会被序列化丢掉', () {
      final blocks = <Block>[
        ImageBlock(alt: '', path: 'a/1.jpg'),
        TextBlock(),
        ImageBlock(alt: '', path: 'a/2.jpg'),
      ];
      expect(serializeBlocks(blocks), '![](a/1.jpg)\n\n![](a/2.jpg)');
    });

    test('alt 含中文与全角括号时能正确解析', () {
      const markdown = '![假期（一）](assets/n1/1.jpg)';
      final blocks = parseBlocks(markdown);
      expect(blocks.single, isA<ImageBlock>());
      expect((blocks.single as ImageBlock).alt, '假期（一）');
      expect(serializeBlocks(blocks), markdown);
    });

    test('alt 含半角括号时能正确解析', () {
      const markdown = '![截图(2)](assets/n1/1.jpg)';
      final blocks = parseBlocks(markdown);
      expect((blocks.single as ImageBlock).alt, '截图(2)');
      expect(serializeBlocks(blocks), markdown);
    });

    test('行尾带空格的图片行仍是图片块，且序列化原样保留空格', () {
      const markdown = '![](assets/n1/1.jpg) ';
      final blocks = parseBlocks(markdown);
      expect(blocks.single, isA<ImageBlock>());
      expect((blocks.single as ImageBlock).path, 'assets/n1/1.jpg');
      expect((blocks.single as ImageBlock).trailing, ' ');
      expect(serializeBlocks(blocks), markdown);
    });

    test('行尾是多个空格或制表符时也能识别成图片块', () {
      for (final trailing in <String>['  ', '\t', ' \t ', '\r']) {
        final markdown = '![](assets/n1/1.jpg)$trailing';
        final blocks = parseBlocks(markdown);
        expect(blocks.single, isA<ImageBlock>(), reason: 'trailing=$trailing');
        expect(
          (blocks.single as ImageBlock).trailing,
          trailing,
          reason: 'trailing=$trailing 应原样保留',
        );
        expect(serializeBlocks(blocks), markdown);
      }
    });

    test('缩进的图片语法仍按文本处理（行首缩进是刻意不容忍的）', () {
      const markdown = '  ![](assets/n1/1.jpg)';
      final blocks = parseBlocks(markdown);
      expect(blocks.single, isA<TextBlock>());
      expect(serializeBlocks(blocks), markdown);
    });

    test('缩进 + 行尾空格的图片语法仍按文本处理', () {
      const markdown = '  ![](assets/n1/1.jpg)  ';
      expect(parseBlocks(markdown).single, isA<TextBlock>());
      expect(serializeBlocks(parseBlocks(markdown)), markdown);
    });

    test('CRLF 行尾的文件链接能识别成文件块，\\r 原样保留', () {
      const markdown = '[f.pdf](a/f.pdf)\r\n';
      final blocks = parseBlocks(markdown);
      expect(blocks.first, isA<FileBlock>());
      expect((blocks.first as FileBlock).name, 'f.pdf');
      expect((blocks.first as FileBlock).trailing, '\r');
      expect(serializeBlocks(blocks), '[f.pdf](a/f.pdf)\r');
    });

    test('行尾带空格的文件链接能识别成文件块', () {
      const markdown = '[f.pdf](a/f.pdf)  ';
      final blocks = parseBlocks(markdown);
      expect(blocks.single, isA<FileBlock>());
      expect((blocks.single as FileBlock).trailing, '  ');
      expect(serializeBlocks(blocks), markdown);
    });

    test('缩进的文件链接仍按文本处理', () {
      const markdown = '  [f.pdf](a/f.pdf)';
      expect(parseBlocks(markdown).single, isA<TextBlock>());
      expect(serializeBlocks(parseBlocks(markdown)), markdown);
    });

    test('图片路径中含空格时按文本处理（无损）', () {
      const markdown = '![](assets/n1/my photo.jpg)';
      final blocks = parseBlocks(markdown);
      expect(blocks.single, isA<TextBlock>());
      expect(serializeBlocks(blocks), markdown);
    });

    test('imageBlocksOf 只抽图片块并保持顺序', () {
      const markdown = '文案\n![](a/1.jpg)\n[附件.pdf](a/1.pdf)\n![](a/2.jpg)';
      final images = imageBlocksOf(markdown);
      expect(images.map((block) => block.path).toList(), <String>['a/1.jpg', 'a/2.jpg']);
    });

    test('纯文本笔记抽取图片块得到空列表', () {
      expect(imageBlocksOf('只有文字'), isEmpty);
    });
  });

  group('边界：换行符', () {
    test('CRLF 混入时正文往返无损', () {
      const markdown = '第一行\r\n第二行\n第三行';
      expect(serializeBlocks(parseBlocks(markdown)), markdown);
    });

    test('CRLF 行尾的图片行仍是图片块，且序列化原样保留 \\r', () {
      const markdown = '![](assets/n1/1.jpg)\r\n文字';
      final blocks = parseBlocks(markdown);
      expect(blocks.length, 2);
      expect(blocks.first, isA<ImageBlock>());
      expect((blocks.first as ImageBlock).path, 'assets/n1/1.jpg');
      expect((blocks.first as ImageBlock).trailing, '\r');
      expect(serializeBlocks(blocks), markdown);
    });

    test('CRLF 正文的摘要仍能剥掉图片语法', () {
      const markdown = '文字\r\n![](assets/n1/1.jpg)\r\n结束';
      final plain = plainSummary(markdown);
      expect(plain, '文字\n结束');
    });

    test('CRLF 换行的图片行也能拿到缩略图（Windows 编辑器改过的文件）', () {
      // 回归用：图片块正则原先卡死 `\)$`，行尾的 \r 让它匹配失败，
      // 图片于是退化成文本块，列表缩略图与编辑页图片渲染一起消失。
      // 现在行尾空白/CR 被单独捕获，既能识别成图片块，又能原样写回。
      const markdown = '![](assets/n1/1.jpg)\r\n';
      final images = imageBlocksOf(markdown);
      expect(images.length, 1);
      expect(images.single.path, 'assets/n1/1.jpg');
      expect((images.single).trailing, '\r');

      // 注意：末尾的 \r\n 只会剩下 \r。文档末尾的空文本块是「给用户继续输入」
      // 的占位，序列化时会被丢掉，因此末尾换行本来就会被归一化掉 ——
      // 这属于契约里明确允许的「末尾换行归一化」，不是这次改动引入的。
      // 关键点是 CRLF 与 LF 现在行为一致：
      expect(serializeBlocks(parseBlocks(markdown)), '![](assets/n1/1.jpg)\r');
      expect(
        serializeBlocks(parseBlocks('![](assets/n1/1.jpg)\n')),
        '![](assets/n1/1.jpg)',
      );
    });
  });

  group('边界：摘要', () {
    test('只有图片的笔记摘要是空串', () {
      expect(plainSummary('![](a/1.jpg)'), '');
    });

    test('只有空行的笔记摘要是空串', () {
      expect(plainSummary('\n\n\n'), '');
    });

    test('只有空白字符的笔记摘要是空串', () {
      expect(plainSummary(' \t \n  '), '');
    });

    test('分隔线不进入摘要', () {
      const markdown = '上文\n\n---\n\n下文';
      expect(plainSummary(markdown), '上文\n下文');
    });

    test('代码围栏标记被剥掉但代码内容保留', () {
      const markdown = '```dart\nfinal a = 1;\n```';
      expect(plainSummary(markdown), 'final a = 1;');
    });
  });
}
