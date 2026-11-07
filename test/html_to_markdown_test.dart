import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/lab/html_to_markdown.dart';

void main() {
  group('htmlToMarkdown', () {
    test('标题与段落', () {
      final String md = htmlToMarkdown(
        '<h1>大标题</h1><h3>小标题</h3><p>第一段</p><p>第二段</p>',
      );
      expect(md, contains('# 大标题'));
      expect(md, contains('### 小标题'));
      expect(md, contains('第一段'));
      expect(md, contains('第二段'));
    });

    test('行内样式与链接', () {
      final String md = htmlToMarkdown(
        '<p>这是 <strong>加粗</strong>、<em>斜体</em>、'
        '<del>删除</del> 和 <code>代码</code>，'
        '还有 <a href="https://example.com/a">链接</a>。</p>',
      );
      expect(md, contains('**加粗**'));
      expect(md, contains('*斜体*'));
      expect(md, contains('~~删除~~'));
      expect(md, contains('`代码`'));
      expect(md, contains('[链接](https://example.com/a)'));
    });

    test('无序与有序列表', () {
      final String md = htmlToMarkdown(
        '<ul><li>苹果</li><li>香蕉</li></ul>'
        '<ol><li>第一步</li><li>第二步</li></ol>',
      );
      expect(md, contains('- 苹果'));
      expect(md, contains('- 香蕉'));
      expect(md, contains('1. 第一步'));
      expect(md, contains('2. 第二步'));
    });

    test('代码块保留内容与实体', () {
      final String md = htmlToMarkdown(
        '<pre><code>if (a &lt; b &amp;&amp; c &gt; d) {}</code></pre>',
      );
      expect(md, contains('```'));
      expect(md, contains('if (a < b && c > d) {}'));
    });

    test('引用块逐行加 >', () {
      final String md = htmlToMarkdown(
        '<blockquote><p>第一行</p><p>第二行</p></blockquote>',
      );
      expect(md, contains('> 第一行'));
      expect(md, contains('> 第二行'));
    });

    test('图片转成普通链接，脚本与样式被丢弃', () {
      final String md = htmlToMarkdown(
        '<style>.a{color:red}</style>'
        '<script>alert(1)</script>'
        '<p>看这张图</p>'
        '<img src="https://example.com/a.png" alt="示例">',
      );
      expect(md, isNot(contains('alert')));
      expect(md, isNot(contains('color:red')));
      expect(md, contains('[示例](https://example.com/a.png)'));
    });
  });
}
