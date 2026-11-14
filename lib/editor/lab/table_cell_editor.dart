import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kDoubleTapTimeout, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/super_editor.dart';

/// 列宽 = 内容自适应，但每条列最多 [maxWidth]，超出的单元格内换行。
///
/// Flutter 自带的 `MaxColumnWidth` 是「取两个宽度的较大者」，没有封顶
/// 语义，所以这里单独实现。
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

/// 桌面表格组件：双击单元格就地编辑，单击仍为整表选中。
///
/// 内核的 [MarkdownTableComponent] 是只读 + 整块选中（没有单元格光标），
/// 这里自建一份桌面版：结构、边框、列宽与内核一致，只在每个单元格上
/// 多挂一个「双击进入编辑」的手势。移动端继续用内核组件，不受影响。
class EditableTableComponentBuilder extends MarkdownTableComponentBuilder {
  const EditableTableComponentBuilder({
    required this.availableWidth,
    required this.selectionColor,
    required this.cursorColor,
    required this.editorBackground,
    this.columnMax = 240,
    this.fillWidth = false,
    this.onCellCommitted,
  }) : super(fit: TableComponentFit.scroll);

  /// 正文内容区宽度（已扣掉页面左右页边距）。
  final double availableWidth;

  /// 表格是整块选中：必须给它一个可见的选中底色，否则用户不知道
  /// 已经选中，也就不会想到可以复制。
  final Color selectionColor;

  /// 单元格编辑框的描边与光标色。
  final Color cursorColor;

  /// 单元格编辑框的底色（盖住下面原来的文字）。
  final Color editorBackground;

  /// 单列宽度上限：手机/平板 240，桌面放宽到 320。
  final double columnMax;

  /// 桌面：表格铺满正文宽度、各列等分（Notion / 语雀的桌面形态），
  /// 不再按内容宽度收缩 + 横向滚动。
  final bool fillWidth;

  /// 单元格内容提交回调；为 null 时不启用双击编辑。
  final void Function(String tableNodeId, int row, int column, String text)?
      onCellCommitted;

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
    viewModel.selectionColor = selectionColor;
    final int columns = node.columnCount;
    if (fillWidth) {
      // 铺满正文宽度、各列等分：与 Notion / 语雀 桌面版一致。
      viewModel.columnWidth = const FlexColumnWidth();
    } else if (columns > 0 && availableWidth > 0) {
      final double cap = (availableWidth / columns).clamp(96, columnMax);
      viewModel.columnWidth = CappedIntrinsicColumnWidth(cap.toDouble());
    }
    return viewModel;
  }

  @override
  Widget? createComponent(
    SingleColumnDocumentComponentContext componentContext,
    SingleColumnLayoutComponentViewModel componentViewModel,
  ) {
    if (componentViewModel is! MarkdownTableViewModel) {
      return null;
    }
    return EditableTableComponent(
      componentKey: componentContext.componentKey,
      viewModel: componentViewModel,
      cursorColor: cursorColor,
      editorBackground: editorBackground,
      fillWidth: fillWidth,
      onCellCommitted: onCellCommitted,
    );
  }
}

/// 表格组件本体：绘制与内核一致，单元格支持双击就地编辑。
class EditableTableComponent extends StatefulWidget {
  const EditableTableComponent({
    super.key,
    required this.componentKey,
    required this.viewModel,
    required this.cursorColor,
    required this.editorBackground,
    this.fillWidth = false,
    this.onCellCommitted,
  });

  final GlobalKey componentKey;
  final MarkdownTableViewModel viewModel;
  final Color cursorColor;
  final Color editorBackground;

  /// 铺满正文宽度（桌面形态），不再横向滚动。
  final bool fillWidth;
  final void Function(String tableNodeId, int row, int column, String text)?
      onCellCommitted;

  @override
  State<EditableTableComponent> createState() => _EditableTableComponentState();
}

class _EditableTableComponentState extends State<EditableTableComponent> {
  final ScrollController _scrollController = ScrollController();

  /// 正在编辑的单元格；null 表示没有在编辑。
  int? _editRow;
  int? _editColumn;
  TextEditingController? _controller;
  FocusNode? _focusNode;

  bool get _editable => widget.onCellCommitted != null;

  /// 每个单元格的锚点：双击时用它把指针坐标换算成「第几行第几列」。
  final Map<int, GlobalKey> _cellKeys = <int, GlobalKey>{};

  /// 上一次按下鼠标的时间 / 位置，用于自己判双击。
  ///
  /// 不用 GestureDetector.onDoubleTap：它会参与手势竞技场，把内核的
  /// 「单击选中整表」拖慢甚至吃掉；Listener 只观察指针，不抢手势。
  DateTime? _lastTapTime;
  Offset? _lastTapPosition;

  GlobalKey _cellKey(int row, int column) {
    return _cellKeys.putIfAbsent(row * 1000 + column, () => GlobalKey());
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (!_editable || _editRow != null) {
      return;
    }
    final DateTime now = DateTime.now();
    final DateTime? lastTime = _lastTapTime;
    final Offset? lastPosition = _lastTapPosition;
    _lastTapTime = now;
    _lastTapPosition = event.position;
    if (lastTime == null || lastPosition == null) {
      return;
    }
    if (now.difference(lastTime) > kDoubleTapTimeout) {
      return;
    }
    if ((event.position - lastPosition).distance > kTouchSlop) {
      return;
    }
    final (int, int)? cell = _cellAt(event.position);
    if (cell != null) {
      _lastTapTime = null;
      _lastTapPosition = null;
      _beginEditing(cell.$1, cell.$2);
    }
  }

  /// 指针落在哪个单元格上；不在表格内返回 null。
  (int, int)? _cellAt(Offset globalPosition) {
    for (final MapEntry<int, GlobalKey> entry in _cellKeys.entries) {
      final RenderObject? renderObject =
          entry.value.currentContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.attached) {
        continue;
      }
      final Offset local = renderObject.globalToLocal(globalPosition);
      if (local.dx >= 0 &&
          local.dy >= 0 &&
          local.dx <= renderObject.size.width &&
          local.dy <= renderObject.size.height) {
        return (entry.key ~/ 1000, entry.key % 1000);
      }
    }
    return null;
  }

  @override
  void didUpdateWidget(covariant EditableTableComponent oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 表格被外部替换（撤销 / 恢复历史版本）后，正在编辑的格子可能已不存在。
    final int? row = _editRow;
    final int? column = _editColumn;
    if (row != null && column != null) {
      final List<List<MarkdownTableCellViewModel>> cells =
          widget.viewModel.cells;
      if (row >= cells.length || column >= cells[row].length) {
        _resetEditing();
      }
    }
  }

  @override
  void dispose() {
    _resetEditing();
    _scrollController.dispose();
    super.dispose();
  }

  void _resetEditing() {
    final TextEditingController? controller = _controller;
    final FocusNode? focusNode = _focusNode;
    // 先清空引用：focusNode.dispose() 会触发一次失焦监听，靠引用判断直接返回。
    _controller = null;
    _focusNode = null;
    _editRow = null;
    _editColumn = null;
    controller?.dispose();
    focusNode?.dispose();
  }

  void _beginEditing(int row, int column) {
    if (!_editable) {
      return;
    }
    if (_editRow == row && _editColumn == column) {
      return;
    }
    _resetEditing();

    final MarkdownTableCellViewModel cell = widget.viewModel.cells[row][column];
    final TextEditingController controller =
        TextEditingController(text: cell.text.toPlainText());
    final FocusNode focusNode = FocusNode(debugLabel: 'xiaoji-table-cell');
    focusNode.addListener(() {
      // 点到正文其它位置时提交：编辑框失焦但内容不能丢。
      if (_focusNode == focusNode && !focusNode.hasFocus) {
        _commitEditing();
      }
    });

    setState(() {
      _editRow = row;
      _editColumn = column;
      _controller = controller;
      _focusNode = focusNode;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _focusNode != focusNode) {
        return;
      }
      focusNode.requestFocus();
      // 全选原内容：双击进入编辑后直接输入就是「替换这一格」。
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: controller.text.length,
      );
    });
  }

  /// 提交编辑。[cancel] 为真时丢弃输入。
  ///
  /// [moveNext] / [movePrevious] 用于 Tab / Shift+Tab：提交后按行列顺序
  /// 切到下一格继续编辑（表格里最常用的连续录入方式）。
  void _commitEditing({
    bool moveNext = false,
    bool movePrevious = false,
    bool cancel = false,
  }) {
    final int? row = _editRow;
    final int? column = _editColumn;
    final TextEditingController? controller = _controller;
    if (row == null || column == null || controller == null) {
      return;
    }

    final List<List<MarkdownTableCellViewModel>> cells = widget.viewModel.cells;
    final String original = cells[row][column].text.toPlainText();
    final String text = controller.text.replaceAll('\n', ' ');

    int? nextRow;
    int? nextColumn;
    if (moveNext || movePrevious) {
      final int rowCount = cells.length;
      final int columnCount = cells[row].length;
      int index = row * columnCount + column + (moveNext ? 1 : -1);
      if (index >= 0 && index < rowCount * columnCount) {
        nextRow = index ~/ columnCount;
        nextColumn = index % columnCount;
      }
    }

    _resetEditing();
    setState(() {});

    if (!cancel && text != original) {
      widget.onCellCommitted!(widget.viewModel.nodeId, row, column, text);
    }
    if (!cancel && nextRow != null && nextColumn != null) {
      final int targetRow = nextRow;
      final int targetColumn = nextColumn;
      // 等内核把新表格重建出来，再在新单元格上开编辑框。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _beginEditing(targetRow, targetColumn);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget table = _buildInteractiveTable(context);
    if (widget.fillWidth) {
      // 桌面：表格本身就是正文宽度（列宽 FlexColumnWidth 等分），
      // 不需要横向滚动容器；外层的 Table 撑满父级可用宽度。
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(width: double.infinity, child: table),
      );
    }
    return SingleAxisTrackpadAndWheelScroller(
      axis: Axis.horizontal,
      controller: _scrollController,
      child: Center(
        child: Scrollbar(
          controller: _scrollController,
          scrollbarOrientation: ScrollbarOrientation.bottom,
          child: SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            child: table,
          ),
        ),
      ),
    );
  }

  /// 可交互的表格主体：单击选表交给内核，双击进入单元格编辑。
  Widget _buildInteractiveTable(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      hitTestBehavior: HitTestBehavior.translucent,
      // Listener 只观察指针、不参与手势竞技场：双击进入单元格编辑，
      // 单击仍然完整交给内核去选中整表（与官方组件同一套行为）。
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _handlePointerDown,
        // 非编辑态保持忽略指针（官方组件的做法，保证点按选表不被
        // 内容层吃掉）；进入编辑后放开，编辑框才能正常点选文字。
        child: IgnorePointer(
          ignoring: _editRow == null,
          child: SelectableBox(
            selection: widget.viewModel.selection?.nodeSelection
                    is UpstreamDownstreamNodeSelection
                ? widget.viewModel.selection?.nodeSelection
                    as UpstreamDownstreamNodeSelection
                : null,
            selectionColor: widget.viewModel.selectionColor,
            child: BoxComponent(
              key: widget.componentKey,
              opacity: widget.viewModel.opacity,
              child: _buildTable(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTable(BuildContext context) {
    final List<List<MarkdownTableCellViewModel>> cells = widget.viewModel.cells;
    return Table(
      border: widget.viewModel.border ?? TableBorder.all(),
      defaultColumnWidth: widget.viewModel.columnWidth,
      children: <TableRow>[
        for (int row = 0; row < cells.length; row++)
          TableRow(
            children: <Widget>[
              for (int column = 0; column < cells[row].length; column++)
                _buildCell(context, row, column, cells[row][column]),
            ],
          ),
      ],
    );
  }

  Widget _buildCell(
    BuildContext context,
    int row,
    int column,
    MarkdownTableCellViewModel cell,
  ) {
    final Widget text = Text.rich(
      cell.text.computeInlineSpan(
        context,
        cell.textStyleBuilder,
        widget.viewModel.inlineWidgetBuilders,
      ),
      textAlign: cell.textAlign,
    );
    final bool editing = _editRow == row && _editColumn == column;

    final Widget content = editing
        ? Stack(
            children: <Widget>[
              // 保留原文字撑住单元格宽高，编辑框浮在上面，进入编辑不跳版。
              text,
              Positioned.fill(child: _buildCellEditor(cell)),
            ],
          )
        : text;

    final Widget padded = Padding(padding: cell.padding, child: content);
    final BoxDecoration decoration = cell.decoration ?? const BoxDecoration();
    return DecoratedBox(
      decoration: decoration,
      // 锚点仅用于把双击坐标换算成行列，不影响命中测试。
      child: KeyedSubtree(key: _cellKey(row, column), child: padded),
    );
  }

  Widget _buildCellEditor(MarkdownTableCellViewModel cell) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.tab): () =>
            _commitEditing(moveNext: true),
        const SingleActivator(LogicalKeyboardKey.tab, shift: true): () =>
            _commitEditing(movePrevious: true),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            _commitEditing(cancel: true),
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: widget.editorBackground,
          border: Border.all(color: widget.cursorColor, width: 1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          style: cell.textStyleBuilder(const <Attribution>{}),
          textAlign: cell.textAlign,
          cursorColor: widget.cursorColor,
          maxLines: 1,
          // 回车提交：表格单元格是单行内容，换行会破坏 Markdown 表格。
          onSubmitted: (_) => _commitEditing(),
          onTapOutside: (_) => _commitEditing(),
          decoration: const InputDecoration(
            isDense: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(horizontal: 2),
            counterText: '',
          ),
        ),
      ),
    );
  }
}
