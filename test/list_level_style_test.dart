import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/markdown_view.dart';
import 'package:xiaoji/theme/app_theme.dart';

/// 阅读态多级列表的编号分层：1. → a. → i.，无序 • → ◦ → ▪。
/// 只改显示，不改源码（源码仍是合法十进制编号，往返无损）。
void main() {
  String flattened(WidgetTester tester, String markdown) {
    late String result;
    awaiter() {
      final colors = AppColors.of(tester.element(find.byType(Scaffold)));
      final spans = markdownSpans(
        markdown,
        const TextStyle(fontSize: 17),
        colors,
      );
      final buffer = StringBuffer();
      void visit(TextSpan node) {
        if (node.text != null) {
          buffer.write(node.text);
        }
        for (final InlineSpan child in node.children ?? const <InlineSpan>[]) {
          if (child is TextSpan) {
            visit(child);
          }
        }
      }

      visit(TextSpan(children: spans));
      result = buffer.toString();
    }

    awaiter();
    return result;
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
  }

  testWidgets('二级有序列表显示为 a. b.，三级显示为 i. ii.', (WidgetTester tester) async {
    await pump(tester);
    final text = flattened(
      tester,
      '1. 甲\n2. 乙\n  1. 子\n  2. 丑\n    1. 孙\n    2. 酉',
    );
    expect(text, contains('1.  甲'));
    expect(text, contains('a.  子'));
    expect(text, contains('b.  丑'));
    expect(text, contains('i.  孙'));
    expect(text, contains('ii.  酉'));
  });

  testWidgets('二级无序列表符号换成空心圆，三级实心小方块', (WidgetTester tester) async {
    await pump(tester);
    final text = flattened(tester, '- 甲\n  - 子\n    - 孙');
    expect(text, contains('•  甲'));
    expect(text, contains('◦  子'));
    expect(text, contains('▪  孙'));
  });

  testWidgets('罗马数字走标准减法记法：4 → iv, 9 → ix', (WidgetTester tester) async {
    await pump(tester);
    final text = flattened(tester, '1. 甲\n    4. 子\n    9. 丑');
    expect(text, contains('iv.  子'));
    expect(text, contains('ix.  丑'));
  });
}
