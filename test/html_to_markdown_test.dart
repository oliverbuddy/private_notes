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

    test('嵌套列表保留层级（两空格缩进）', () {
      final String md = htmlToMarkdown(
        '<ul><li><p>一级</p>'
        '<ul><li><p>二级</p>'
        '<ol><li>三级</li></ol>'
        '</li></ul>'
        '</li><li><p>同级</p></li></ul>',
      );
      expect(md, contains('- 一级'));
      expect(md, contains('  - 二级'));
      expect(md, contains('    1. 三级'));
      expect(md, contains('- 同级'));
      // 子项不能再被压成顶层
      expect(md, isNot(contains('\n- 二级')));
    });

    test('待办列表转成 - [ ] / - [x]', () {
      final String md = htmlToMarkdown(
        '<ul><li><input type="checkbox" checked> 已完成</li>'
        '<li><input type="checkbox"> 未完成</li></ul>',
      );
      expect(md, contains('- [x] 已完成'));
      expect(md, contains('- [ ] 未完成'));
    });

    test('有序列表保留 start 起始编号', () {
      final String md = htmlToMarkdown(
        '<ol start="3"><li>第三</li><li>第四</li></ol>',
      );
      expect(md, contains('3. 第三'));
      expect(md, contains('4. 第四'));
    });

    test('代码块保留语言标记', () {
      final String md = htmlToMarkdown(
        '<pre><code class="language-dart">void main() {}</code></pre>',
      );
      expect(md, contains('```dart'));
    });

    test('链接保留 title', () {
      final String md = htmlToMarkdown(
        '<p><a href="https://x.test" title="示例">文字</a></p>',
      );
      expect(md, contains('[文字](https://x.test "示例")'));
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

    test('HTML 表格转 GFM 管道表格', () {
      final String md = htmlToMarkdown(
        '<table><thead><tr><th>名称</th><th>数量</th></tr></thead>'
        '<tbody><tr><td>苹果</td><td>3</td></tr>'
        '<tr><td>香蕉</td><td>5</td></tr></tbody></table>',
      );
      expect(md, contains('| 名称 | 数量 |'));
      expect(md, contains('| --- | --- |'));
      expect(md, contains('| 苹果 | 3 |'));
      expect(md, contains('| 香蕉 | 5 |'));
    });

    test('命名实体与数字实体都还原成符号', () {
      final String md = htmlToMarkdown(
        '<p>破折号&mdash;省略&hellip;&ldquo;引号&rdquo;'
        '&#8212;&#x2014;版权&copy;数量&times;2</p>',
      );
      expect(md, contains('破折号—省略…'));
      expect(md, contains('“引号”'));
      expect(md, contains('——版权©数量×2'));
      expect(md, isNot(contains('&mdash;')));
      expect(md, isNot(contains('&copy;')));
    });

    test('实体里的 &amp; 不会被二次解码', () {
      final String md = htmlToMarkdown('<p>&amp;mdash; 是字面量</p>');
      expect(md, contains('&mdash; 是字面量'));
    });

    test('<mark> 高亮转成 ==…==', () {
      final String md = htmlToMarkdown('<p>这是 <mark>重点</mark> 内容</p>');
      expect(md, contains('==重点=='));
    });

    test('表格对齐与 colspan', () {
      final String md = htmlToMarkdown(
        '<table><tr><th align="center">左</th>'
        '<th style="text-align:right">右</th></tr>'
        '<tr><td colspan="2">合并</td></tr></table>',
      );
      expect(md, contains('| :---: | ---: |'));
      expect(md, contains('| 合并 |  |'));
    });
  });
}
