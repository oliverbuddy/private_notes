import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/markdown_view.dart';
import 'package:xiaoji/theme/app_theme.dart';

/// 阅读态的契约只有一条：**屏幕上看不到 markdown 记号**。
/// 编辑态是另一套（记号保留但淡显），两边规则要分开验。
String render(String markdown) {
  final spans = markdownSpans(
    markdown,
    const TextStyle(fontSize: 17),
    AppColors.light,
  );
  return spans.map(_spanText).join();
}

/// 标签现在是 WidgetSpan 胶囊，`toPlainText()` 只会返回占位符，
/// 这里把胶囊里的 Text 内容也展开，契约仍然是「屏幕上看不到记号」。
String _spanText(InlineSpan span) {
  if (span is TextSpan) {
    final String text = span.text ?? '';
    final String children = span.children?.map(_spanText).join() ?? '';
    return '$text$children';
  }
  if (span is WidgetSpan) {
    return _widgetText(span.child);
  }
  return '';
}

String _widgetText(Widget widget) {
  if (widget is Text) {
    return widget.data ?? '';
  }
  if (widget is Container) {
    final Widget? child = widget.child;
    return child == null ? '' : _widgetText(child);
  }
  return '';
}

void main() {
  group('阅读态剔除 markdown 记号', () {
    test('标题去掉 # 前缀，保留文字', () {
      final text = render('## 关于说人话');
      expect(text, contains('关于说人话'));
      expect(text, isNot(contains('##')));
      expect(text, isNot(contains('#')));
    });

    test('加粗 / 斜体 / 删除线 / 行内代码的记号都消失', () {
      final text = render('这是**加粗**、*斜体*、~~删除~~、`代码`');
      expect(text, contains('加粗'));
      expect(text, contains('斜体'));
      expect(text, contains('删除'));
      expect(text, contains('代码'));
      expect(text.contains('*'), isFalse);
      expect(text.contains('~'), isFalse);
      expect(text.contains('`'), isFalse);
    });

    test('链接只留文字，不显示括号和地址', () {
      final text = render('看这个[语雀小记](https://yuque.com)很好用');
      expect(text, contains('语雀小记'));
      expect(text, isNot(contains('https://')));
      expect(text, isNot(contains('](')));
    });

    test('待办渲染成勾选框，不显示 - [ ]', () {
      final open = render('- [ ] 写完补一段');
      expect(open, contains('写完补一段'));
      expect(open, isNot(contains('[ ]')));
      expect(open, isNot(contains('- ')));

      final done = render('- [x] 删掉副词');
      expect(done, contains('删掉副词'));
      expect(done, isNot(contains('[x]')));
    });

    test('无序列表换成圆点，有序列表保留序号', () {
      expect(render('- 第一项'), contains('•'));
      expect(render('- 第一项'), isNot(contains('- ')));

      final ordered = render('1. 第一步');
      expect(ordered, contains('1.'));
      expect(ordered, contains('第一步'));
    });

    test('引用去掉 > 但保留内容', () {
      final text = render('> 如果你解释不清');
      expect(text, contains('如果你解释不清'));
      expect(text, isNot(contains('>')));
    });

    test('标签保留 #，因为 # 就是它的样子', () {
      final text = render('今天在想 #写作 这件事');
      expect(text, contains('#写作'));
    });

    test('分隔线不出现三个减号', () {
      final text = render('上文\n\n---\n\n下文');
      expect(text.contains('---'), isFalse);
      expect(text, contains('上文'));
      expect(text, contains('下文'));
    });

    test('代码围栏本身不显示，内容保留', () {
      final text = render('```\nfinal x = 1;\n```');
      expect(text, contains('final x = 1;'));
      expect(text.contains('```'), isFalse);
    });

    test('代码内容里含 ``` 时，用加长围栏仍能正确闭合', () {
      // 写入端在内容含 ``` 时会把围栏加长成 ````，预览必须按同长度闭合，
      // 否则代码后半段会被当成正文。
      final text = render('````\n```dart\nfinal x = 1;\n```\n````\n\n后文');
      expect(text, contains('```dart'));
      expect(text, contains('final x = 1;'));
      expect(text, contains('后文'));
    });

    test('高亮的 == 记号消失，只剩带底色的文字', () {
      final List<InlineSpan> spans = markdownSpans(
        '这是 ==重点== 内容',
        const TextStyle(fontSize: 17),
        AppColors.light,
      );
      expect(spans.map(_spanText).join(), '这是 重点 内容');
      final highlighted = spans.whereType<TextSpan>().where(
            (TextSpan span) => span.style?.backgroundColor != null,
          );
      expect(highlighted.length, 1);
      expect(highlighted.first.text, '重点');
    });

    test('普通段落原样输出', () {
      expect(render('就一句话'), '就一句话');
    });
  });

  group('代码块整宽卡片', () {
    testWidgets('列表摘要里的代码块与详情一样铺满整行', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                child: MarkdownBlockView(
                  text: '```dart\nvoid main() {}\n```',
                  baseSize: 16,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final Finder code = find.text('void main() {}');
      expect(code, findsOneWidget);
      final Finder card = find
          .ancestor(of: code, matching: find.byType(Container))
          .first;
      expect(
        tester.getSize(card).width,
        closeTo(300, 1),
        reason: '摘要里的代码块也要是整宽卡片，不能只包住文字',
      );
    });
  });

  group('标签胶囊', () {
    test('正文里的标签字号压到正文的 0.78，避免背景过大', () {
      final List<InlineSpan> spans = markdownSpans(
        '今天 #工作 完成',
        const TextStyle(fontSize: 16),
        AppColors.light,
      );
      final WidgetSpan tagSpan = spans.whereType<WidgetSpan>().first;
      final Container capsule = tagSpan.child as Container;
      final Text label = capsule.child! as Text;
      expect(label.style!.fontSize, closeTo(16 * 0.78, 0.01));
    });
  });

  group('excerptSource', () {
    test('表格行压成单行，分隔行不出现', () {
      final String source = excerptSource(
        '| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |',
      );
      expect(source, '名称 · 数量\n苹果 · 3');
    });

    test('普通文本中的竖线不误伤', () {
      expect(excerptSource('a | b'), 'a | b');
    });
  });
}
