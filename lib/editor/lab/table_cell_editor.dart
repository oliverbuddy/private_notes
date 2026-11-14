import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/super_editor.dart';

/// 表格结构操作（右键菜单 / Tab 加行共用）。
enum TableCellAction {
  insertRowAbove,
  insertRowBelow,
  insertColumnLeft,
  insertColumnRight,
  deleteRow,
  deleteColumn,
}

/// 按 [action] 重建表格节点；不允许的操作返回 null（菜单负责置灰）。
///
/// 内核的 [TableBlockNode] 不可变，插入 / 删除行列都要整表重建：未改动的
/// 单元格复用原 [TextNode]（id 不变，撤销与光标映射都更稳），新单元格
/// 用 [Editor.createNodeId] 生成。表头行不能删除（表格必须保留表头），
/// 最后一列也不能删。
TableBlockNode? rebuildTableNode(
  TableBlockNode table,
  TableCellAction action,
  int row,
  int column,
) {
  final int rowCount = table.rowCount;
  final int columnCount = table.columnCount;
  if (rowCount == 0 || columnCount == 0) {
    return null;
  }
  if (row < 0 || row >= rowCount || column < 0 || column >= columnCount) {
    return null;
  }

  List<List<TextNode>> snapshot() => <List<TextNode>>[
        for (int r = 0; r < rowCount; r++)
          <TextNode>[
            for (int c = 0; c < columnCount; c++)
              table.getCell(rowIndex: r, columnIndex: c),
          ],
      ];
  TextNode emptyCell() =>
      TextNode(id: Editor.createNodeId(), text: AttributedText());

  final List<List<TextNode>> cells;
  switch (action) {
    case TableCellAction.insertRowAbove:
      cells = snapshot()
        ..insert(
          row,
          List<TextNode>.generate(columnCount, (_) => emptyCell()),
        );
    case TableCellAction.insertRowBelow:
      cells = snapshot()
        ..insert(
          row + 1,
          List<TextNode>.generate(columnCount, (_) => emptyCell()),
        );
    case TableCellAction.insertColumnLeft:
    case TableCellAction.insertColumnRight:
      final int at = action == TableCellAction.insertColumnLeft
          ? column
          : column + 1;
      cells = snapshot();
      for (final List<TextNode> rowCells in cells) {
        rowCells.insert(at, emptyCell());
      }
    case TableCellAction.deleteRow:
      // 表头是表格的语义基准，删掉就没有表格了。
      if (row == 0 || rowCount <= 1) {
        return null;
      }
      cells = snapshot()..removeAt(row);
    case TableCellAction.deleteColumn:
      if (columnCount <= 1) {
        return null;
      }
      cells = snapshot();
      for (final List<TextNode> rowCells in cells) {
        rowCells.removeAt(column);
      }
  }
  return TableBlockNode(
    id: table.id,
    cells: cells,
    metadata: Map<String, dynamic>.from(table.metadata),
  );
}

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
    this.onCellStructure,
    this.onCellPointerDown,
    this.onCellEditingChanged,
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

  /// 表格结构操作（插入 / 删除行列）；为 null 时右键菜单不提供结构操作。
  final void Function(
    String tableNodeId,
    TableCellAction action,
    int row,
    int column,
  )? onCellStructure;

  /// 指针在单元格上按下：右键菜单需要知道「哪一行哪一列」。
  final void Function(String tableNodeId, int row, int column)?
      onCellPointerDown;

  /// 单元格编辑状态变化（页面据此避免拦截 ⌘C / ⌘V，交给输入框自己处理）。
  final ValueChanged<bool>? onCellEditingChanged;

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
      onCellStructure: onCellStructure,
      onCellPointerDown: onCellPointerDown,
      onCellEditingChanged: onCellEditingChanged,
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
    this.onCellStructure,
    this.onCellPointerDown,
    this.onCellEditingChanged,
  });

  final GlobalKey componentKey;
  final MarkdownTableViewModel viewModel;
  final Color cursorColor;
  final Color editorBackground;

  /// 铺满正文宽度（桌面形态），不再横向滚动。
  final bool fillWidth;
  final void Function(String tableNodeId, int row, int column, String text)?
      onCellCommitted;

  /// 结构操作回调（Tab 到末格加行 / 右键菜单）；组件本身不改文档。
  final void Function(
    String tableNodeId,
    TableCellAction action,
    int row,
    int column,
  )? onCellStructure;

  /// 指针按下时上报单元格位置（右键菜单定位目标行列）。
  final void Function(String tableNodeId, int row, int column)?
      onCellPointerDown;

  /// 单元格编辑状态变化（页面据此避免拦截 ⌘C / ⌘V）。
  final ValueChanged<bool>? onCellEditingChanged;

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

  /// 本次编辑开始的时间：用来区分「内核抢焦点」和「用户点走」。
  DateTime _editingStartedAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _editable => widget.onCellCommitted != null;

  /// 每个单元格的锚点：按下时用它把指针坐标换算成「第几行第几列」。
  final Map<int, GlobalKey> _cellKeys = <int, GlobalKey>{};

  GlobalKey _cellKey(int row, int column) {
    return _cellKeys.putIfAbsent(row * 1000 + column, () => GlobalKey());
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (!_editable) {
      return;
    }
    // 右键：把「哪一行哪一列」上报给页面，右键菜单据此做结构操作
    // （插入 / 删除行列）。菜单本身由页面统一弹，避免两个菜单同时出现。
    if (event.buttons == kSecondaryMouseButton) {
      final (int, int)? cell = _cellAt(event.position);
      if (cell != null) {
        widget.onCellPointerDown?.call(
          widget.viewModel.nodeId,
          cell.$1,
          cell.$2,
        );
      }
      return;
    }
    if (_editRow != null) {
      return;
    }
    // 单击即进入编辑（Word / 语雀 / Notion 的表格都是这个语义）：
    // 进编辑后单元格里的文字可以拖选、⌘C 复制，不再只能整表选中。
    final (int, int)? cell = _cellAt(event.position);
    if (cell != null) {
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
    if (_editRow == row && _editColumn == column && _focusNode != null) {
      _grabFocus();
      return;
    }
    // 换格：先把上一格的输入提交掉，不能丢掉用户刚敲的内容。
    if (_editRow != null) {
      _commitEditing();
      if (_editRow == row && _editColumn == column) {
        return;
      }
    }

    final List<List<MarkdownTableCellViewModel>> cells = widget.viewModel.cells;
    if (row < 0 || row >= cells.length) {
      return;
    }
    if (column < 0 || column >= cells[row].length) {
      return;
    }
    final MarkdownTableCellViewModel cell = cells[row][column];
    final TextEditingController controller =
        TextEditingController(text: cell.text.toPlainText());
    final FocusNode focusNode = FocusNode(debugLabel: 'xiaoji-table-cell');
    focusNode.addListener(() {
      if (_focusNode != focusNode || focusNode.hasFocus) {
        return;
      }
      // 刚开编辑的 500ms 内失焦，是内核的点击处理在抢正文焦点，不是用户
      // 想离开；直接把焦点抢回来，否则会「一点就退出编辑」。
      if (DateTime.now().difference(_editingStartedAt) <
          const Duration(milliseconds: 500)) {
        focusNode.requestFocus();
        return;
      }
      // 点到别的格子 / 正文：编辑框失焦但内容不能丢。
      _commitEditing();
    });

    _editingStartedAt = DateTime.now();
    setState(() {
      _editRow = row;
      _editColumn = column;
      _controller = controller;
      _focusNode = focusNode;
    });
    widget.onCellEditingChanged?.call(true);
    _grabFocus();
    // 全选原内容：点开编辑后直接输入就是「替换这一格」。
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
  }

  /// 连续几帧确认焦点落在单元格输入框上。
  ///
  /// 首次点击时，内核的鼠标手势会在同一串事件里 requestFocus 正文，
  /// 把刚拿到的编辑框焦点踢掉 —— 表现出来就是「点进去又刷新没了」。
  void _grabFocus() {
    var attempts = 0;
    void tryFocus() {
      if (!mounted) {
        return;
      }
      final FocusNode? node = _focusNode;
      if (node == null) {
        return;
      }
      if (!node.hasFocus) {
        node.requestFocus();
      }
      attempts++;
      // 多补几帧：内核的焦点请求可能晚于本帧。
      if (attempts < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) => tryFocus());
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => tryFocus());
  }

  /// 提交编辑。[cancel] 为真时丢弃输入。
  ///
  /// 与竞品一致的连续录入方式：
  ///  - Enter：提交后光标下移到同列下一行；已在最后一行则新增一行；
  ///  - Tab / Shift+Tab：按行列顺序前后切换，最后一格再 Tab 新增一行；
  ///  - Esc：放弃本次输入。
  void _commitEditing({
    bool moveNext = false,
    bool movePrevious = false,
    bool moveDown = false,
    bool moveUp = false,
    bool cancel = false,
  }) {
    final int? row = _editRow;
    final int? column = _editColumn;
    final TextEditingController? controller = _controller;
    if (row == null || column == null || controller == null) {
      return;
    }
    // 第一行再按 ↑：表格外没有格子，保持编辑态，不关闭。
    if (moveUp && row == 0) {
      return;
    }

    final List<List<MarkdownTableCellViewModel>> cells = widget.viewModel.cells;
    final String original = cells[row][column].text.toPlainText();
    final String text = controller.text.replaceAll('\n', ' ');

    final int rowCount = cells.length;
    final int columnCount = cells[row].length;
    int? nextRow;
    int? nextColumn;
    bool addRow = false;
    if (moveDown) {
      // 表格里最常用的录入方向是「往下填同一列」，不是回车退出。
      nextRow = row + 1;
      nextColumn = column;
      addRow = nextRow >= rowCount;
    } else if (moveUp) {
      nextRow = row - 1;
      nextColumn = column;
    } else if (moveNext || movePrevious) {
      final int index = row * columnCount + column + (moveNext ? 1 : -1);
      if (index >= 0 && index < rowCount * columnCount) {
        nextRow = index ~/ columnCount;
        nextColumn = index % columnCount;
      } else if (moveNext) {
        // 最后一格再 Tab：新增一行并落到新行首列。
        addRow = true;
        nextRow = rowCount;
        nextColumn = 0;
      }
    }

    _resetEditing();
    setState(() {});
    widget.onCellEditingChanged?.call(false);

    if (!cancel && text != original) {
      widget.onCellCommitted!(widget.viewModel.nodeId, row, column, text);
    }
    if (!cancel && addRow) {
      widget.onCellStructure?.call(
        widget.viewModel.nodeId,
        TableCellAction.insertRowBelow,
        rowCount - 1,
        0,
      );
    }
    if (!cancel && nextRow != null && nextColumn != null) {
      final int targetRow = nextRow;
      final int targetColumn = nextColumn;
      // 新增行时表格要等内核重建完才有新单元格，这里带重试地等下一帧。
      _beginEditingAfterRebuild(targetRow, targetColumn);
    }
  }

  /// 等表格重建完成后在新单元格上开编辑框（最多重试 3 帧）。
  void _beginEditingAfterRebuild(int row, int column, {int attempt = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final List<List<MarkdownTableCellViewModel>> cells =
          widget.viewModel.cells;
      if (row < cells.length && column < cells[row].length) {
        _beginEditing(row, column);
        return;
      }
      if (attempt < 3) {
        _beginEditingAfterRebuild(row, column, attempt: attempt + 1);
      }
    });
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
        // ↑ / ↓ 在单元格之间上下移动（Excel / 语雀 的录入方式）。
        const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
            _commitEditing(moveDown: true),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
            _commitEditing(moveUp: true),
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
          // 回车提交并下移：与 Excel / 语雀 的表格录入一致。
          onSubmitted: (_) => _commitEditing(moveDown: true),
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
