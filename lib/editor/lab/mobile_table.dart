import 'package:flutter/material.dart';
import 'package:super_editor/super_editor.dart';

import '../../theme/app_theme.dart';
import 'selection_toolbar.dart';

/// 手机端表格组件：铺满正文宽度，单元格文本可选中复制。
///
/// 内核的 `MarkdownTableComponent` 把整张表当成一个块来选中：
/// `IgnorePointer + SelectableBox` 会吞掉文本手势，单元格里的字既选不中
/// 也复制不了（手机端用户反馈的高频需求）。这里保留同样的 `Table` 布局
/// 与样式，只把单元格换成 [Text]，并用 [SelectionArea] 接管长按选词、
/// 拖手柄扩展与复制菜单。
///
/// 列宽用 [FlexColumnWidth] 均分：表格始终等于正文宽度，长内容在单元格内
/// 换行，不再需要左右滑动（用户反馈：手机上横滑找列很烦）。列宽因此不再
/// 按可用宽度封顶，`availableWidth` 已移除。
class MobileTableComponentBuilder extends MarkdownTableComponentBuilder {
  const MobileTableComponentBuilder() : super();

  @override
  SingleColumnLayoutComponentViewModel? createViewModel(
    Document document,
    DocumentNode node,
  ) {
    final SingleColumnLayoutComponentViewModel? viewModel =
        super.createViewModel(document, node);
    if (viewModel is! MarkdownTableViewModel) {
      return viewModel;
    }
    // 等分列宽：Table 会按父级宽度（正文内容宽度）铺满，多列自动收窄换行。
    viewModel.columnWidth = const FlexColumnWidth();
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
  /// 本次按下期间是否由表格临时关掉了编辑器的长按选块。
  bool _suppressedEditorLongPress = false;

  @override
  void dispose() {
    // 页面在按住表格时被关闭的兜底：别把全局开关留在 true。
    _restoreEditorLongPress();
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
          // 表格是只读内容：长按只给「复制 / 全选」，并与正文长按共用
          // 同一套反色胶囊（[SelectionCapsule]），不再弹系统默认菜单。
          contextMenuBuilder: (
            BuildContext context,
            SelectableRegionState state,
          ) =>
              _TableSelectionMenu(state: state),
          child: _buildTable(context),
        ),
      ),
    );
  }

  Widget _buildTable(BuildContext context) {
    final MarkdownTableViewModel viewModel = widget.viewModel;
    final AppColors colors = AppColors.of(context);
    // 外圈边框由外层 DecoratedBox 画，Table 只保留内网格。
    final TableBorder? source = viewModel.border;
    final BorderSide innerSide = source?.horizontalInside ??
        BorderSide(color: colors.divider, width: 0.8);
    const double borderWidth = 1;
    // 外框必须画在裁剪层**外面**：Container 的 clipBehavior 把 ClipPath
    // 包在 DecoratedBox 里（container.dart 实测），裁剪边界和描边完全重合，
    // 单元格背景正好压掉整条 1px 描边 —— 用户看到的就是「没有边框、
    // 没有圆角」。这里描边由 DecoratedBox 画，正文内容再内缩 [borderWidth]
    // 交给 ClipRRect 圆角裁剪。
    // 外框用 dividerStrong（实色）比内网格 divider（半透明）重一档，
    // 圆角才有对比度。
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.block),
        border: Border.all(color: colors.dividerStrong, width: borderWidth),
      ),
      child: Padding(
        padding: const EdgeInsets.all(borderWidth),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.block - borderWidth),
          child: Table(
            border: TableBorder(
              horizontalInside: innerSide,
              verticalInside: source?.verticalInside ?? innerSide,
            ),
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
        ),
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
}

/// 表格单元格的选区菜单：只读内容，只给「复制 / 全选」。
///
/// 视觉与正文的 `XiaojiSelectionToolbar` 共用 [SelectionCapsule]（反色胶囊、
/// 同一套字号与内边距）。定位必须交给 [TextSelectionToolbar]：
/// `SelectableRegion` 把 `contextMenuBuilder` 的返回值直接塞进根 Overlay，
/// 不做任何锚点或尺寸约束 —— 裸 Widget 会被拉满整屏（用户反馈
/// 「菜单盖住整个屏幕」）。[TextSelectionToolbar] 负责上下避让、屏幕内
/// 夹取与超宽溢出，和框架默认菜单用的是同一套布局。
class _TableSelectionMenu extends StatelessWidget {
  const _TableSelectionMenu({required this.state});

  final SelectableRegionState state;

  @override
  Widget build(BuildContext context) {
    final MaterialLocalizations localizations =
        MaterialLocalizations.of(context);
    final TextSelectionToolbarAnchors anchors = state.contextMenuAnchors;

    return TextSelectionToolbar(
      anchorAbove: anchors.primaryAnchor,
      anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
      // 背景由胶囊自己画，别再叠一层默认的浅色菜单底板。
      toolbarBuilder: (BuildContext context, Widget child) => child,
      children: <Widget>[
        SelectionCapsule(
          key: const ValueKey<String>('table-selection-menu'),
          actions: <SelectionCapsuleAction>[
            SelectionCapsuleAction(
              localizations.copyButtonLabel,
              // 自定义菜单里复制没有替代接口；官方默认菜单内部同样调用它。
              // ignore: deprecated_member_use
              () => state.copySelection(SelectionChangedCause.toolbar),
            ),
            SelectionCapsuleAction(
              localizations.selectAllButtonLabel,
              () => state.selectAll(SelectionChangedCause.toolbar),
            ),
          ],
        ),
      ],
    );
  }
}
