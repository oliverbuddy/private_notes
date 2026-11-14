import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/lab/markdown_shortcut.dart';

void main() {
  group('Markdown 快捷输入前缀', () {
    test('ASCII 记号', () {
      expect(matchMarkdownShortcut('# ')?.shortcut, MarkdownShortcut.h1);
      expect(matchMarkdownShortcut('## ')?.shortcut, MarkdownShortcut.h2);
      expect(matchMarkdownShortcut('### ')?.shortcut, MarkdownShortcut.h3);
      expect(matchMarkdownShortcut('- ')?.shortcut, MarkdownShortcut.bullet);
      expect(matchMarkdownShortcut('* ')?.shortcut, MarkdownShortcut.bullet);
      expect(matchMarkdownShortcut('1. ')?.shortcut, MarkdownShortcut.ordered);
      expect(matchMarkdownShortcut('> ')?.shortcut, MarkdownShortcut.quote);
    });

    test('全角记号与全角空格（中文输入法）', () {
      expect(matchMarkdownShortcut('#\u3000')?.shortcut, MarkdownShortcut.h1);
      expect(
          matchMarkdownShortcut('＋\u3000')?.shortcut, MarkdownShortcut.bullet);
      expect(
          matchMarkdownShortcut('＞\u3000')?.shortcut, MarkdownShortcut.quote);
      expect(matchMarkdownShortcut('1．\u3000')?.shortcut,
          MarkdownShortcut.ordered);
    });

    test('待办前缀', () {
      expect(matchMarkdownShortcut('[] ')?.shortcut, MarkdownShortcut.todo);
      expect(matchMarkdownShortcut('[ ] ')?.shortcut, MarkdownShortcut.todo);
      expect(matchMarkdownShortcut('[x] ')?.shortcut, MarkdownShortcut.todo);
      expect(
          matchMarkdownShortcut('［ ］\u3000')?.shortcut, MarkdownShortcut.todo);
    });

    test('前缀长度包含结尾空格', () {
      expect(matchMarkdownShortcut('## ')?.length, 3);
      expect(matchMarkdownShortcut('[] ')?.length, 3);
      expect(matchMarkdownShortcut('#\u3000')?.length, 2);
    });

    test('不匹配普通文本', () {
      expect(matchMarkdownShortcut(''), isNull);
      expect(matchMarkdownShortcut('#'), isNull);
      expect(matchMarkdownShortcut('# 标题'), isNull);
      expect(matchMarkdownShortcut('第 1. 条'), isNull);
      expect(matchMarkdownShortcut('-'), isNull);
    });
  });
}
