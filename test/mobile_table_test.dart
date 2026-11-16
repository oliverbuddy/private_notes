// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';
import 'package:xiaoji/editor/lab/mobile_table.dart';
import 'package:xiaoji/editor/lab/xiaoji_markdown.dart';
import 'package:xiaoji/theme/app_theme.dart';

void main() {
  group('MobileTableComponentBuilder', () {
    test('表格节点使用封顶的固有列宽', () {
      final MutableDocument document = deserializeXiaojiMarkdown(
        '| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |',
      );
      final TableBlockNode table = document.whereType<TableBlockNode>().single;

      const MobileTableComponentBuilder builder =
          MobileTableComponentBuilder(availableWidth: 324);
      final SingleColumnLayoutComponentViewModel? viewModel =
          builder.createViewModel(document, table);

      expect(viewModel, isA<MarkdownTableViewModel>());
      final MarkdownTableViewModel tableViewModel =
          viewModel! as MarkdownTableViewModel;
      expect(tableViewModel.columnWidth, isA<CappedIntrinsicColumnWidth>());
      // 324 / 2 列 = 162，夹在 96~240 之间。
      expect(
        (tableViewModel.columnWidth as CappedIntrinsicColumnWidth).maxWidth,
        162,
      );
    });

    test('非表格节点不接管', () {
      final MutableDocument document = deserializeXiaojiMarkdown('普通段落');
      final TextNode paragraph = document.getNodeAt(0)! as TextNode;

      const MobileTableComponentBuilder builder =
          MobileTableComponentBuilder(availableWidth: 324);
      expect(builder.createViewModel(document, paragraph), isNull);
    });
  });

  group('MobileTable 长按', () {
    testWidgets('按住表格时暂停编辑器的长按选块，抬起后恢复', (WidgetTester tester) async {
      disableLongPressSelectionForSuperlist = false;
      addTearDown(() => disableLongPressSelectionForSuperlist = false);

      final MutableDocument document = deserializeXiaojiMarkdown(
        '| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |',
      );
      final TableBlockNode table = document.whereType<TableBlockNode>().single;
      final MarkdownTableViewModel viewModel =
          const MobileTableComponentBuilder(availableWidth: 324)
              .createViewModel(document, table)! as MarkdownTableViewModel;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: MobileTable(
              componentKey: GlobalKey(),
              viewModel: viewModel,
            ),
          ),
        ),
      );

      final Offset center =
          tester.getCenter(find.textContaining('苹果', findRichText: true));
      final TestGesture gesture = await tester.startGesture(center);
      await tester.pump();
      expect(
        disableLongPressSelectionForSuperlist,
        isTrue,
        reason: '按住表格时必须先关掉内核的长按选块，避免和文本选择抢',
      );

      await gesture.up();
      await tester.pump();
      expect(
        disableLongPressSelectionForSuperlist,
        isFalse,
        reason: '抬起后要恢复，正文长按选词不受影响',
      );
    });
  });
}
