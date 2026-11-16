// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';
import 'package:xiaoji/editor/lab/mobile_table.dart';
import 'package:xiaoji/editor/lab/xiaoji_markdown.dart';
import 'package:xiaoji/theme/app_theme.dart';

void main() {
  group('MobileTableComponentBuilder', () {
    test('表格列宽均分：铺满正文宽度，不再按内容封顶', () {
      final MutableDocument document = deserializeXiaojiMarkdown(
        '| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |',
      );
      final TableBlockNode table = document.whereType<TableBlockNode>().single;

      const MobileTableComponentBuilder builder =
          MobileTableComponentBuilder();
      final SingleColumnLayoutComponentViewModel? viewModel =
          builder.createViewModel(document, table);

      expect(viewModel, isA<MarkdownTableViewModel>());
      final MarkdownTableViewModel tableViewModel =
          viewModel! as MarkdownTableViewModel;
      // 全宽显示：列宽均分，Table 取父级（正文）宽度铺满，长内容换行。
      expect(tableViewModel.columnWidth, isA<FlexColumnWidth>());
    });

    test('非表格节点不接管', () {
      final MutableDocument document = deserializeXiaojiMarkdown('普通段落');
      final TextNode paragraph = document.getNodeAt(0)! as TextNode;

      const MobileTableComponentBuilder builder =
          MobileTableComponentBuilder();
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
          const MobileTableComponentBuilder()
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

    testWidgets('表格只画内网格，四边交给圆角容器', (WidgetTester tester) async {
      final MutableDocument document = deserializeXiaojiMarkdown(
        '| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |',
      );
      final TableBlockNode table = document.whereType<TableBlockNode>().single;
      final MarkdownTableViewModel viewModel =
          const MobileTableComponentBuilder()
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

      // 四边交给圆角容器画，Table 自身只留内部分隔线，
      // 否则外边框会被圆角裁成不到半像素、看起来「没有边框」。
      final Table tableWidget = tester.widget<Table>(find.byType(Table));
      final TableBorder border = tableWidget.border!;
      expect(border.top, BorderSide.none);
      expect(border.bottom, BorderSide.none);
      expect(border.left, BorderSide.none);
      expect(border.right, BorderSide.none);
      expect(border.horizontalInside, isNot(BorderSide.none));

      // 外圈容器带圆角，且描边画在裁剪层外面（Container 的 clipBehavior
      // 会把 ClipPath 包在 DecoratedBox 里，描边会被单元格背景压掉）。
      final DecoratedBox frame = tester.widget<DecoratedBox>(
        find
            .ancestor(
              of: find.byType(Table),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final BoxDecoration decoration = frame.decoration as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(AppRadius.block));
      expect(decoration.border!.top.width, 1);
      expect(decoration.border!.top.color, AppColors.light.dividerStrong);

      // 内容再内缩 1px 做圆角裁剪，不覆盖描边。
      final ClipRRect clip = tester.widget<ClipRRect>(
        find
            .ancestor(of: find.byType(Table), matching: find.byType(ClipRRect))
            .first,
      );
      expect(
        clip.borderRadius,
        BorderRadius.circular(AppRadius.block - 1),
      );
    });
  });
}
