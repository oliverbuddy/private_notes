import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/theme/app_theme.dart';
import 'package:xiaoji/ui/attachment_preview_page.dart';

void main() {
  testWidgets('长文本附件在回弹滚动物理下仍能拖动滚动', (WidgetTester tester) async {
    final Directory directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('xiaoji_preview_'),
    ))!;
    addTearDown(() => directory.deleteSync(recursive: true));

    // 模拟一份超过一屏的 xml。
    final StringBuffer buffer = StringBuffer('<root>\n');
    for (var i = 0; i < 200; i++) {
      buffer.writeln('<item index="$i">内容 $i</item>');
    }
    buffer.writeln('</root>');
    final File file = File('${directory.path}/config.xml');
    await tester.runAsync(() => file.writeAsString(buffer.toString()));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        // 与 App 一致：Android 上也是回弹物理。
        scrollBehavior: const AppScrollBehavior(),
        home: AttachmentPreviewPage(fileName: 'config.xml', path: file.path),
      ),
    );
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (find.byType(SelectionArea).evaluate().isNotEmpty) {
        break;
      }
    }

    expect(find.byType(SelectionArea), findsOneWidget);
    // 回归护栏：SelectableText 在 BouncingScrollPhysics 下会吞掉拖动手势，
    // 长文本只能停在第一屏。
    expect(find.byType(SelectableText), findsNothing);

    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0));

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -400),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(scrollable.position.pixels, greaterThan(0));
  });
}
