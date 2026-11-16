import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:super_editor/super_editor.dart';

import '../../theme/app_theme.dart';

/// 表格单列宽度上限：正文可用宽度按列数均分，单列夹在 [min] 与 [max] 之间。
///
/// 2~3 列表格在手机上基本一屏放下；列特别多时单列不低于 [min]，宁可
/// 略微横向滚动也不把字挤成一条；平板/PC 因 [availableWidth] 更大，
/// 单列自然更宽，不需要按端写第二套分支。
double tableColumnCap({
  required double availableWidth,
  required int columns,
  double min = 96,
  double max = 240,
}) {
  if (columns <= 0 || availableWidth <= 0) {
    return max;
  }
  return (availableWidth / columns).clamp(min, max).toDouble();
}

/// 列宽按内容取「固有宽度」，但不超过 [maxWidth]。
///
/// 表格内核默认用 [IntrinsicColumnWidth]：长文本会把整张表撑到几千 dp，
/// 手机窄屏必须横向滑很久才能看完。封顶后长内容在单元格内换行。
class CappedIntrinsicColumnWidth extends TableColumnWidth {
  const CappedIntrinsicColumnWidth(this.maxWidth);

  final double maxWidth;

  static const TableColumnWidth _intrinsic = IntrinsicColumnWidth();

  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      math.min(_intrinsic.minIntrinsicWidth(cells, containerWidth), maxWidth);

  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      math.min(_intrinsic.maxIntrinsicWidth(cells, containerWidth), maxWidth);
}

/// 手机端表格组件：在「列宽封顶」的基础上，让单元格文本可选中复制。
///
/// 内核的 `MarkdownTableComponent` 把整张表当成一个块来选中：
/// `IgnorePointer + SelectableBox` 会吞掉文本手势，单元格里的字既选不中
/// 也复制不了（手机端用户反馈的高频需求）。这里保留同样的 `Table` 布局
/// 与样式，只把单元格换成 [Text]，并用 [SelectionArea] 接管长按选词、
/// 拖手柄扩展与系统复制菜单。
class MobileTableComponentBuilder extends MarkdownTableComponentBuilder {
  const MobileTableComponentBuilder({
    required this.availableWidth,
    this.columnMax = 240,
  }) : super(fit: TableComponentFit.scroll);

  /// 正文内容区宽度（已扣掉页面左右页边距）。
  final double availableWidth;

  /// 单列宽度上限：窄屏 240，宽屏（平板）可略宽。
  final double columnMax;

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(
    Document document,
    DocumentNode node,
  ) {
    final SingleColumnLayoutComponentViewModel? viewModel =
        super.createViewModel(document, node);
    if (viewModel is! MarkdownTableViewModel || node is! TableBlockNode) {
      return viewModel;
    }
    final int columns = node.columnCount;
    if (columns > 0 && availableWidth > 0) {
      viewModel.columnWidth = CappedIntrinsicColumnWidth(
        tableColumnCap(
          availableWidth: availableWidth,
          columns: columns,
          max: columnMax,
        ),
      );
    }
    return viewModel;
  }

  @override
  Widget? createComponent(
    SingleColumnDocumentComponentContext componentContext,
    SingleColumnLayoutComponentViewModel componentViewModel,
  ) {
    // createComponent 会被所有 builder 依次调用，必须按 ViewModel 类型过滤，
    // 否则会把别人的组件顶掉。
    if (componentViewModel is! MarkdownTableViewModel) {
      return null;
    }
    return MobileTable(
      componentKey: componentContext.componentKey,
      viewModel: componentViewModel,
    );
  }
}

/// 可选中复制文本的只读表格。
class MobileTable extends StatefulWidget {
  const MobileTable({
    super.key,
    required this.componentKey,
    required this.viewModel,
  });

  /// 文档布局用来定位与测量这一块的 key，必须挂在最外层。
  final GlobalKey componentKey;

  final MarkdownTableViewModel viewModel;

  @override
  State<MobileTable> createState() => _MobileTableState();
}

class _MobileTableState extends State<MobileTable> {
  final ScrollController _scrollController = ScrollController();

  /// 本次按下期间是否由表格临时关掉了编辑器的长按选块。
  bool _suppressedEditorLongPress = false;

  @override
  void dispose() {
    // 页面在按住表格时被关闭的兜底：别把全局开关留在 true。
    _restoreEditorLongPress();
    _scrollController.dispose();
    super.dispose();
  }

  /// 表格按下时，临时关掉 super_editor 自己的长按选块。
  ///
  /// 内核的长按不是手势竞技场里的识别器，而是 `onTapDown` 之后直接起
  /// 500ms 定时器：它和 SelectionArea 的长按同时到点，谁先执行不稳定。
  /// 抢输的那次就会把整张表当成块选中、requestFocus 并把光标落到表格
  /// 下方，表现为「长按选单元格时页面隔三差五往下滚一下」。
  /// 内核提供了 `disableLongPressSelectionForSuperlist` 开关，这里只在
  /// 手指按在表格上的这段时间打开，抬起即恢复，不影响正文长按选词。
  void _suppressEditorLongPress() {
    // 内核这个开关被标记为 deprecated（issue #1547）：组件与文档手势都是
    // translucent，长按会同时触发两套逻辑。但它正是当前唯一可用的官方
    // 逃生口 —— 表格自己用 SelectionArea 处理长按，需要让内核那套让路。
    // ignore: deprecated_member_use
    if (!disableLongPressSelectionForSuperlist) {
      // ignore: deprecated_member_use
      disableLongPressSelectionForSuperlist = true;
      _suppressedEditorLongPress = true;
    }
  }

  void _restoreEditorLongPress() {
    if (_suppressedEditorLongPress) {
      // ignore: deprecated_member_use
      disableLongPressSelectionForSuperlist = false;
      _suppressedEditorLongPress = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // BoxComponent 只画不透明度，但它的 State 实现了 DocumentComponent：
    // 滚动定位、光标/选区几何都靠这个接口，不能换成裸 Widget。
    return BoxComponent(
      key: widget.componentKey,
      opacity: widget.viewModel.opacity,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _suppressEditorLongPress(),
        onPointerUp: (_) => _restoreEditorLongPress(),
        onPointerCancel: (_) => _restoreEditorLongPress(),
        child: SelectionArea(
          child: _buildFit(context, _buildTable(context)),
        ),
      ),
    );
  }

  Widget _buildTable(BuildContext context) {
    final MarkdownTableViewModel viewModel = widget.viewModel;
    // 外圈圆角：网格线本身是直角，裁一下四角后与卡片的圆角语言一致，
    // 不再是一块「贴在正文里的生硬表格」。滚动条在裁剪层外面，不受影响。
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.block),
      child: Table(
        border: viewModel.border ?? TableBorder.all(),
        defaultColumnWidth: viewModel.columnWidth,
        children: <TableRow>[
          for (final List<MarkdownTableCellViewModel> row in viewModel.cells)
            TableRow(
              children: <Widget>[
                for (final MarkdownTableCellViewModel cell in row)
                  DecoratedBox(
                    decoration: cell.decoration ?? const BoxDecoration(),
                    child: Padding(
                      padding: cell.padding,
                      child: Text.rich(
                        _cellSpan(context, cell),
                        textAlign: cell.textAlign,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// 单元格的富文本 span（样式来自表格样式表）。
  TextSpan _cellSpan(BuildContext context, MarkdownTableCellViewModel cell) {
    final InlineSpan span = cell.text.computeInlineSpan(
      context,
      cell.textStyleBuilder,
      widget.viewModel.inlineWidgetBuilders,
    );
    return span is TextSpan ? span : TextSpan(children: <InlineSpan>[span]);
  }

  Widget _buildFit(BuildContext context, Widget table) {
    switch (widget.viewModel.fit) {
      case TableComponentFit.scroll:
        // 列特别多、单列窄于下限时保留横向滚动兜底；removePadding 避免
        // 页面安全区把滚动条顶出表格底边（内核同样的处理）。
        return MediaQuery.removePadding(
          context: context,
          removeTop: true,
          removeBottom: true,
          removeLeft: true,
          removeRight: true,
          child: Scrollbar(
            controller: _scrollController,
            scrollbarOrientation: ScrollbarOrientation.bottom,
            child: SingleChildScrollView(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              child: table,
            ),
          ),
        );
      case TableComponentFit.scale:
        return LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            return FittedBox(
              fit: BoxFit.scaleDown,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: table,
              ),
            );
          },
        );
    }
  }
}
