import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/util/text_highlight.dart';

const TextStyle _style = TextStyle(fontSize: 14);
const Color _highlight = Color(0xFFFFF176);

List<TextSpan> _spans(String text, String query) {
  return highlightSpans(
    text: text,
    query: query,
    style: _style,
    highlightColor: _highlight,
  );
}

List<String> _texts(String text, String query) {
  return _spans(text, query).map((span) => span.text ?? '').toList();
}

void main() {
  group('边界：空输入', () {
    test('空查询返回单个完整 span', () {
      final spans = _spans('今天去旅行', '');
      expect(spans.length, 1);
      expect(spans.single.text, '今天去旅行');
      expect(spans.single.style?.backgroundColor, isNull);
    });

    test('纯空格查询等同于空查询', () {
      final spans = _spans('今天去旅行', '   ');
      expect(spans.length, 1);
      expect(spans.single.text, '今天去旅行');
    });

    test('空文本返回单个空 span', () {
      final spans = _spans('', '旅行');
      expect(spans.length, 1);
      expect(spans.single.text, '');
    });

    test('未命中时返回单个完整 span', () {
      final spans = _spans('今天去旅行', '加班');
      expect(spans.length, 1);
      expect(spans.single.text, '今天去旅行');
      expect(spans.single.style?.backgroundColor, isNull);
    });
  });

  group('边界：命中位置', () {
    test('开头命中时不产生空的前置 span', () {
      expect(_texts('旅行记录', '旅行'), <String>['旅行', '记录']);
    });

    test('结尾命中时没有残留空 span', () {
      expect(_texts('今天去旅行', '旅行'), <String>['今天去', '旅行']);
    });

    test('整段命中时只有一个 span', () {
      expect(_texts('旅行', '旅行'), <String>['旅行']);
    });

    test('中文多次命中位置正确', () {
      expect(
        _texts('今天去旅行，明天也旅行', '旅行'),
        <String>['今天去', '旅行', '，明天也', '旅行'],
      );
    });

    test('每次都命中的情况下 span 拼接等于原文', () {
      const text = 'abcabcabc';
      final joined = _texts(text, 'abc').join();
      expect(joined, text);
    });

    test('多个命中时只有命中段带底色', () {
      final spans = _spans('今天去旅行，明天也旅行', '旅行');
      final highlighted = spans
          .where((span) => span.style?.backgroundColor == _highlight)
          .toList();
      expect(highlighted.length, 2);
      expect(highlighted.every((span) => span.text == '旅行'), isTrue);
    });

    test('英文命中大小写不敏感且保留原文大小写', () {
      expect(_texts('Flutter Dev', 'FLU'), <String>['Flu', 'tter Dev']);
    });

    test('查询前后空格被裁掉后仍能命中', () {
      expect(_texts('今天去旅行', '  旅行  '), <String>['今天去', '旅行']);
    });
  });

  group('边界：重叠与异常输入', () {
    test('重叠关键字不会死循环也不会越界', () {
      final texts = _texts('aaa', 'aa');
      expect(texts.join(), 'aaa');
    });

    test('关键字比文本长时安全返回原文', () {
      expect(_texts('ab', 'abcdef'), <String>['ab']);
    });

    test('特殊正则字符被当作普通文本', () {
      final texts = _texts(r'价格 (元) 100*', r'(元)');
      expect(texts.join(), r'价格 (元) 100*');
      expect(texts.contains(r'(元)'), isTrue);
    });

    test('命中长文本每一处都带底色', () {
      final spans = _spans('aaaa', 'a');
      expect(spans.length, 4);
      expect(
        spans.every((span) => span.style?.backgroundColor == _highlight),
        isTrue,
      );
    });

    test('emoji 混排时偏移量不越界', () {
      final texts = _texts('😀 今天去旅行', '旅行');
      expect(texts.join(), '😀 今天去旅行');
      expect(texts.contains('旅行'), isTrue);
    });
  });
}
