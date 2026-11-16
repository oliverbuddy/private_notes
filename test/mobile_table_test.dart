import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';
import 'package:xiaoji/editor/lab/mobile_table.dart';
import 'package:xiaoji/editor/lab/xiaoji_markdown.dart';

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
}
