import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/super_editor.dart';

import '../../theme/app_theme.dart';
import '../../ui/pressable.dart';

/// 表格结构操作（右键菜单 / Tab 加行 / Cmd+Enter 加行共用）。
///
/// 与 Typora 的表格右键菜单一一对应：插入行列、移动行列、删除行列。
enum TableCellAction {
  insertRowAbove,
  insertRowBelow,
  insertColumnLeft,
  insertColumnRight,
  moveRowUp,
  moveRowDown,
  moveColumnLeft,
  moveColumnRight,
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

  List<List<TextNode>> snapshot() => _tableGrid(table);
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
    case TableCellAction.moveRowUp:
      // 第 0 行是表头，数据行只能移动到表头之下（Typora 的表格同样以
      // 首行为表头）。
      if (row <= 1) {
        return null;
      }
      cells = snapshot();
      final List<TextNode> movedUp = cells.removeAt(row);
      cells.insert(row - 1, movedUp);
    case TableCellAction.moveRowDown:
      if (row < 1 || row >= rowCount - 1) {
        return null;
      }
      cells = snapshot();
      final List<TextNode> movedDown = cells.removeAt(row);
      cells.insert(row + 1, movedDown);
    case TableCellAction.moveColumnLeft:
      if (column <= 0) {
        return null;
      }
      cells = snapshot();
      for (final List<TextNode> rowCells in cells) {
        final TextNode moved = rowCells.removeAt(column);
        rowCells.insert(column - 1, moved);
      }
    case TableCellAction.moveColumnRight:
      if (column >= columnCount - 1) {
        return null;
      }
      cells = snapshot();
      for (final List<TextNode> rowCells in cells) {
        final TextNode moved = rowCells.removeAt(column);
        rowCells.insert(column + 1, moved);
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

List<List<TextNode>> _tableGrid(TableBlockNode table) => <List<TextNode>>[
      for (int r = 0; r < table.rowCount; r++)
        <TextNode>[
          for (int c = 0; c < table.columnCount; c++)
            table.getCell(rowIndex: r, columnIndex: c),
        ],
    ];

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

/// Typora 式表格构建器（桌面）。
///
/// 内核的 [MarkdownTableComponent] 只有整块选中、没有单元格光标；这里用
/// 自建组件重建一套「文字里直接出光标」的表格，交互按 Typora 的语义实现，
/// 结构、边框、列宽仍走 [MarkdownTableViewModel]，与内核保持一致。
class TyporaTableComponentBuilder extends MarkdownTableComponentBuilder {
  const TyporaTableComponentBuilder({
    required this.availableWidth,
    required this.selectionColor,
    required this.cursorColor,
    this.editorFocusNode,
    this.columnMax = 240,
    this.fillWidth = false,
    this.onCellCommitted,
    this.onCellStructure,
    this.onCellPointerDown,
    this.onColumnAlign,
    this.onCellEditingChanged,
  }) : super(fit: TableComponentFit.scroll);

  /// 正文内容区宽度（已扣掉页面左右页边距）。
  final double availableWidth;

  /// 表格整块选中时的底色（右键操作前需要让用户看到选中范围）。
  final Color selectionColor;

  /// 单元格光标色。
  final Color cursorColor;

  /// 正文编辑器的焦点节点：点表格时内核会顺手把焦点交给它，组件据此
  /// 判断「焦点是被抢走的」并抢回单元格。
  final FocusNode? editorFocusNode;

  /// 单列宽度上限：手机/平板 240，桌面放宽到 320。
  final double columnMax;

  /// 桌面：表格铺满正文宽度、各列等分，不再按内容宽度收缩 + 横向滚动。
  final bool fillWidth;

  /// 单元格内容提交回调；为 null 时不启用编辑。
  final void Function(
    String tableNodeId,
    int row,
    int column,
    AttributedText text,
  )? onCellCommitted;

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

  /// 整列对齐（Typora 表格工具条上的对齐按钮）。
  final void Function(String tableNodeId, int column, String align)?
      onColumnAlign;

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
    if (columns > 0 && availableWidth > 0) {
      // 兜底宽度：真正的列宽由组件按「内容自适应」算（见 TyporaTable），
      // 这里只保证 VM 有一个合理值。
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
    return TyporaTable(
      componentKey: componentContext.componentKey,
      viewModel: componentViewModel,
      cursorColor: cursorColor,
      editorFocusNode: editorFocusNode,
      fillWidth: fillWidth,
      onCellCommitted: onCellCommitted,
      onCellStructure: onCellStructure,
      onCellPointerDown: onCellPointerDown,
      onColumnAlign: onColumnAlign,
      onCellEditingChanged: onCellEditingChanged,
    );
  }
}

/// Typora 式表格：单元格就是文字本身，点进去直接出现光标。
///
/// 交互约定（与 Typora 一致）：
///  - 单击单元格：光标落在点击位置，可直接输入；按下后拖拽可选中格内文字；
///  - Tab / Shift+Tab：前后切换单元格，最后一格再 Tab 自动加一行；
///  - Enter / Shift+Enter：格内换行（写回 `<br>`）；
///  - Cmd/Ctrl+Enter：当前行下方插入空行；
///  - ↑ / ↓：同列上下移动（最后一行 ↓ 加行）；← / → 在文字首尾跨格；
///  - Esc：放弃本次输入；点击别处：提交。
class TyporaTable extends StatefulWidget {
  const TyporaTable({
    super.key,
    required this.componentKey,
    required this.viewModel,
    required this.cursorColor,
    this.editorFocusNode,
    this.fillWidth = false,
    this.onCellCommitted,
    this.onCellStructure,
    this.onCellPointerDown,
    this.onColumnAlign,
    this.onCellEditingChanged,
  });

  final GlobalKey componentKey;
  final MarkdownTableViewModel viewModel;
  final Color cursorColor;

  /// 正文编辑器的焦点节点（用来判断焦点是不是被内核抢走的）。
  final FocusNode? editorFocusNode;
  final bool fillWidth;

  final void Function(
    String tableNodeId,
    int row,
    int column,
    AttributedText text,
  )? onCellCommitted;

  final void Function(
    String tableNodeId,
    TableCellAction action,
    int row,
    int column,
  )? onCellStructure;

  final void Function(String tableNodeId, int row, int column)?
      onCellPointerDown;

  /// 整列对齐（Typora 表格工具条上的对齐按钮）。
  final void Function(String tableNodeId, int column, String align)?
      onColumnAlign;

  final ValueChanged<bool>? onCellEditingChanged;

  @override
  State<TyporaTable> createState() => _TyporaTableState();
}

class _TyporaTableState extends State<TyporaTable> {
  final ScrollController _scrollController = ScrollController();

  /// 正在编辑的单元格；null 表示没有在编辑。
  int? _editRow;
  int? _editColumn;
  _CellTextController? _controller;
  FocusNode? _focusNode;

  /// 最近一次指针落在单元格上的时间：用来区分「内核抢焦点」和「用户点走」。
  DateTime _lastTablePointerAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 一次「按下即输入」的手势里，拖拽选字的起点（光标偏移）。
  int? _dragAnchorOffset;
  (int, int)? _dragCell;

  /// 当前悬停的单元格（浮动工具条用）。
  int? _hoverRow;
  int? _hoverColumn;

  /// 最后一次落光标的单元格：指针移到工具条上时，悬停位置可能已经变了，
  /// 工具条的对齐/增删要以「光标在哪一格」为准（Typora 的语义）。
  int? _cursorRow;
  int? _cursorColumn;

  bool get _editable => widget.onCellCommitted != null;

  /// 单元格锚点：把指针坐标换算成「第几行第几列」，也用来算光标偏移。
  final Map<int, GlobalKey> _cellKeys = <int, GlobalKey>{};

  /// 工具条锚点：指针在工具条上时不能按几何位置重算单元格 —— 工具条
  /// 浮在表格右上角，几何上会命中它下方的那一格，导致「对齐/插入」作用
  /// 到最后一列（用户反馈的操作位置错乱）。
  final GlobalKey _toolbarKey = GlobalKey();

  bool _pointerOnToolbar(Offset globalPosition) {
    final RenderObject? renderObject =
        _toolbarKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      return false;
    }
    final Offset local = renderObject.globalToLocal(globalPosition);
    return local.dx >= 0 &&
        local.dy >= 0 &&
        local.dx <= renderObject.size.width &&
        local.dy <= renderObject.size.height;
  }

  GlobalKey _cellKey(int row, int column) =>
      _cellKeys.putIfAbsent(row * 1000 + column, () => GlobalKey());

  @override
  void didUpdateWidget(covariant TyporaTable oldWidget) {
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
    final int? hoverRow = _hoverRow;
    if (hoverRow != null &&
        (hoverRow >= widget.viewModel.cells.length ||
            (_hoverColumn ?? 0) >= widget.viewModel.cells[hoverRow].length)) {
      _hoverRow = null;
      _hoverColumn = null;
    }
  }

  @override
  void dispose() {
    _resetEditing();
    _scrollController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 编辑态
  // ---------------------------------------------------------------------------

  void _resetEditing() {
    final _CellTextController? controller = _controller;
    final FocusNode? focusNode = _focusNode;
    // 先清空引用：dispose 会触发一次失焦监听，靠引用判断直接返回。
    _controller = null;
    _focusNode = null;
    _editRow = null;
    _editColumn = null;
    _dragAnchorOffset = null;
    _dragCell = null;
    controller?.dispose();
    focusNode?.dispose();
  }

  /// 进入某格编辑。[offset] 为光标落点，[selectAll] 为切格后全选便于覆盖。
  void _beginEditing(
    int row,
    int column, {
    int? offset,
    bool selectAll = false,
  }) {
    if (!_editable) {
      return;
    }
    if (_editRow == row && _editColumn == column && _focusNode != null) {
      _grabFocus();
      return;
    }
    if (_editRow != null) {
      _commitEditing();
    }
    final List<List<MarkdownTableCellViewModel>> cells = widget.viewModel.cells;
    if (row < 0 || row >= cells.length) {
      return;
    }
    if (column < 0 || column >= cells[row].length) {
      return;
    }
    final MarkdownTableCellViewModel cell = cells[row][column];
    final _CellTextController controller = _CellTextController(
      source: cell.text,
      styleBuilder: cell.textStyleBuilder,
    );
    final FocusNode focusNode = FocusNode(debugLabel: 'xiaoji-typora-cell');
    // 键盘语义挂在焦点节点上：能读到组词状态，输入法候选里的回车不会被
    // 当成「换格 / 加行」。
    focusNode.onKeyEvent =
        (FocusNode node, KeyEvent event) => _handleCellKey(row, column, event);
    focusNode.addListener(() {
      if (_focusNode != focusNode || focusNode.hasFocus) {
        return;
      }
      // 只有「刚点了表格、焦点却被正文编辑器抢走」这一种情况才抢回来。
      // 之前用的是时间窗口，既救不回晚到的抢焦点（要点两次才能落光标），
      // 又会把「点开格子后点别处」硬拽回来。这里按焦点归属 + 是否刚点过
      // 表格判断：用户点正文时事件更早，不会误抢。
      final FocusNode? editorFocus = widget.editorFocusNode;
      final FocusNode? primary = FocusManager.instance.primaryFocus;
      final bool kernelStoleFocus =
          editorFocus != null && identical(primary, editorFocus);
      if (kernelStoleFocus &&
          DateTime.now().difference(_lastTablePointerAt) <
              const Duration(milliseconds: 300)) {
        focusNode.requestFocus();
        return;
      }
      // 不能在这个 FocusNode 的变更通知里同步提交：_commitEditing 会
      // dispose 该节点，框架会直接断言（dispose during notifyListeners）。
      scheduleMicrotask(() {
        if (!mounted || _focusNode != focusNode) {
          return;
        }
        _commitEditing();
      });
    });

    setState(() {
      _editRow = row;
      _editColumn = column;
      _cursorRow = row;
      _cursorColumn = column;
      _controller = controller;
      _focusNode = focusNode;
    });
    widget.onCellEditingChanged?.call(true);
    _grabFocus();
    if (selectAll) {
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: controller.text.length,
      );
    } else if (offset != null) {
      controller.selection = TextSelection.collapsed(
        offset: offset.clamp(0, controller.text.length),
      );
    } else {
      controller.selection =
          TextSelection.collapsed(offset: controller.text.length);
    }
  }

  /// 连续几帧确认焦点落在单元格上（内核会在同一串事件里抢一次正文焦点）。
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
      if (attempts < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) => tryFocus());
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => tryFocus());
  }

  KeyEventResult _handleCellKey(int row, int column, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _commitEditing(cancel: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      if (keyboard.isShiftPressed) {
        _commitEditing(movePrevious: true);
      } else {
        _commitEditing(moveNext: true);
      }
      return KeyEventResult.handled;
    }
    final _CellTextController? controller = _controller;
    if (controller == null) {
      return KeyEventResult.ignored;
    }
    // 组词中不劫持按键，交给输入法确认候选。
    final TextRange composing = controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    // Cmd/Ctrl+Enter：当前行下方插一行（Typora 的表格快捷键）。
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        (keyboard.isMetaPressed || keyboard.isControlPressed)) {
      _commitEditing();
      widget.onCellStructure?.call(
        widget.viewModel.nodeId,
        TableCellAction.insertRowBelow,
        row,
        0,
      );
      // 光标留在原格继续录入（Typora 插行后不打断输入）。
      _beginEditingAfterRebuild(row, column);
      return KeyEventResult.handled;
    }
    // 普通 Enter / Shift+Enter：格内换行（写回 `<br>`），不切格。
    // ⌥↑/↓/←/→：移动整行 / 整列（Typora 的表格快捷键）。
    // 必须排在普通方向键之前，否则会被「上下切行」吃掉。
    if (keyboard.isAltPressed) {
      TableCellAction? move;
      if (key == LogicalKeyboardKey.arrowUp) {
        move = TableCellAction.moveRowUp;
      } else if (key == LogicalKeyboardKey.arrowDown) {
        move = TableCellAction.moveRowDown;
      } else if (key == LogicalKeyboardKey.arrowLeft) {
        move = TableCellAction.moveColumnLeft;
      } else if (key == LogicalKeyboardKey.arrowRight) {
        move = TableCellAction.moveColumnRight;
      }
      if (move != null) {
        _commitEditing();
        widget.onCellStructure?.call(
          widget.viewModel.nodeId,
          move,
          row,
          column,
        );
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _commitEditing(moveDown: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _commitEditing(moveUp: true);
      return KeyEventResult.handled;
    }
    final TextSelection selection = controller.selection;
    // ⇧⌘⌫：删除本行（Typora 的 Delete Row）。
    if (key == LogicalKeyboardKey.backspace &&
        keyboard.isMetaPressed &&
        keyboard.isShiftPressed) {
      _commitEditing();
      widget.onCellStructure?.call(
        widget.viewModel.nodeId,
        TableCellAction.deleteRow,
        row,
        column,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft &&
        selection.isValid &&
        selection.isCollapsed &&
        selection.baseOffset == 0) {
      _commitEditing(movePrevious: true, allowAddRow: false);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight &&
        selection.isValid &&
        selection.isCollapsed &&
        selection.baseOffset >= controller.text.length) {
      _commitEditing(moveNext: true, allowAddRow: false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 提交编辑。[cancel] 为真时丢弃输入。
  ///
  ///  - Tab / Shift+Tab：按行列顺序前后切换，最后一格再 Tab 新增一行；
  ///  - ↓ / ↑：提交后移动到同列下一行 / 上一行（最后一行 ↓ 新增一行）；
  ///  - Esc：放弃本次输入；点击别处 / 失去焦点：提交。
  void _commitEditing({
    bool moveNext = false,
    bool movePrevious = false,
    bool moveDown = false,
    bool moveUp = false,
    bool allowAddRow = true,
    bool cancel = false,
  }) {
    final int? row = _editRow;
    final int? column = _editColumn;
    final _CellTextController? controller = _controller;
    if (row == null || column == null || controller == null) {
      return;
    }
    // 第一行再按 ↑：表格外没有格子，保持编辑态，不关闭。
    if (moveUp && row == 0) {
      return;
    }
    final List<List<MarkdownTableCellViewModel>> cells = widget.viewModel.cells;
    if (row >= cells.length || column >= cells[row].length) {
      _resetEditing();
      setState(() {});
      return;
    }

    final AttributedText original = cells[row][column].text;
    final String originalText = original.toPlainText();
    // 内容没动就沿用原属性，避免「点一下没改」也重建节点。
    final AttributedText submitted = controller.text == originalText
        ? original
        : controller.attributedValue();
    final bool changed = !cancel && controller.text != originalText;

    final int rowCount = cells.length;
    final int columnCount = cells[row].length;
    int? nextRow;
    int? nextColumn;
    bool addRow = false;
    if (moveDown) {
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
        if (!allowAddRow) {
          return;
        }
        addRow = true;
        nextRow = rowCount;
        nextColumn = 0;
      }
    }

    _resetEditing();
    setState(() {});
    widget.onCellEditingChanged?.call(false);

    if (changed) {
      widget.onCellCommitted!(widget.viewModel.nodeId, row, column, submitted);
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
      _beginEditingAfterRebuild(targetRow, targetColumn);
    }
  }

  /// 等表格重建完成后在目标格上开编辑（最多重试 3 帧）。
  void _beginEditingAfterRebuild(
    int row,
    int column, {
    int attempt = 0,
    bool selectAll = true,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final List<List<MarkdownTableCellViewModel>> cells =
          widget.viewModel.cells;
      if (row < cells.length && column < cells[row].length) {
        _beginEditing(row, column, selectAll: selectAll);
        return;
      }
      if (attempt < 3) {
        _beginEditingAfterRebuild(
          row,
          column,
          attempt: attempt + 1,
          selectAll: selectAll,
        );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // 指针
  // ---------------------------------------------------------------------------

  void _handlePointerDown(PointerDownEvent event) {
    if (!_editable) {
      return;
    }
    final (int, int)? cell = _cellAt(event.position);
    if (cell != null) {
      _lastTablePointerAt = DateTime.now();
      widget.onCellPointerDown?.call(
        widget.viewModel.nodeId,
        cell.$1,
        cell.$2,
      );
    }
    if (event.buttons == kSecondaryMouseButton) {
      return;
    }
    if (cell == null) {
      _commitEditing();
      return;
    }
    // 已经在编辑这一格：光标/拖选交给输入框自己处理。
    if (_editRow == cell.$1 && _editColumn == cell.$2) {
      return;
    }
    if (_editRow != null) {
      _commitEditing();
    }
    final int offset = _caretOffsetAt(
      event.position,
      cell.$1,
      cell.$2,
      widget.viewModel.cells[cell.$1][cell.$2],
    );
    _beginEditing(cell.$1, cell.$2, offset: offset);
    // 记下起点：同一次按下手势里的拖拽要能选中文字（内核输入框此刻
    // 才刚出现，收不到这次手势的拖选事件）。
    _dragAnchorOffset = offset;
    _dragCell = cell;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final int? anchor = _dragAnchorOffset;
    final (int, int)? dragCell = _dragCell;
    final _CellTextController? controller = _controller;
    if (anchor == null || dragCell == null || controller == null) {
      return;
    }
    final (int, int)? cell = _cellAt(event.position);
    if (cell == null || cell != dragCell) {
      return;
    }
    if (controller.text !=
        widget.viewModel.cells[dragCell.$1][dragCell.$2].text.toPlainText()) {
      // 已经开始输入，拖选交给输入框。
      return;
    }
    final int offset = _caretOffsetAt(
      event.position,
      dragCell.$1,
      dragCell.$2,
      widget.viewModel.cells[dragCell.$1][dragCell.$2],
    );
    controller.selection = TextSelection(
      baseOffset: anchor,
      extentOffset: offset,
    );
  }

  void _handlePointerUp(PointerEvent event) {
    _dragAnchorOffset = null;
    _dragCell = null;
  }

  /// 把点击位置换算成单元格文字里的光标偏移。
  int _caretOffsetAt(
    Offset globalPosition,
    int row,
    int column,
    MarkdownTableCellViewModel cell,
  ) {
    final String plain = cell.text.toPlainText();
    final RenderObject? renderObject =
        _cellKey(row, column).currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached) {
      return plain.length;
    }
    final Offset local = renderObject.globalToLocal(globalPosition);
    final EdgeInsets padding = cell.padding.resolve(TextDirection.ltr);
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: plain,
        style: cell.textStyleBuilder(const <Attribution>{}),
      ),
      textDirection: TextDirection.ltr,
      textAlign: cell.textAlign,
    )..layout(
        maxWidth:
            math.max(0, renderObject.size.width - padding.horizontal),
      );
    final TextPosition position = painter.getPositionForOffset(
      Offset(local.dx - padding.left, local.dy - padding.top),
    );
    painter.dispose();
    return position.offset.clamp(0, plain.length);
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

  // ---------------------------------------------------------------------------
  // 悬停 / 列宽
  // ---------------------------------------------------------------------------

  int get _columnCount =>
      widget.viewModel.cells.isEmpty ? 0 : widget.viewModel.cells.first.length;

  String? _contentWidthsKey;
  List<double>? _contentWidthsCache;

  /// 按内容算列宽：Typora 的表格是浏览器 auto 布局 —— 每列宽度由该列
  /// 最长的一行文字决定，整体超过正文宽度时按比例压缩（单元格内换行）。
  List<double> _contentWidths(double available) {
    final List<List<MarkdownTableCellViewModel>> cells = widget.viewModel.cells;
    final int columns = _columnCount;
    if (columns == 0 || cells.isEmpty) {
      return const <double>[];
    }
    // 内容 / 宽度 / 字号没变就复用，避免每帧重新排版。
    final TextStyle probeStyle = cells.first.first.textStyleBuilder(
      const <Attribution>{},
    );
    final String key = <String>[
      widget.viewModel.nodeId,
      available.toStringAsFixed(1),
      '${probeStyle.fontSize}|${probeStyle.fontFamily}',
      for (final List<MarkdownTableCellViewModel> row in cells)
        row.map((MarkdownTableCellViewModel c) => c.text.toPlainText()).join('\u0001'),
    ].join('\u0002');
    if (_contentWidthsKey == key && _contentWidthsCache != null) {
      return _contentWidthsCache!;
    }

    const double minWidth = 56;
    final List<double> desired = List<double>.filled(columns, minWidth);
    for (final List<MarkdownTableCellViewModel> row in cells) {
      for (var c = 0; c < row.length && c < columns; c++) {
        final MarkdownTableCellViewModel cell = row[c];
        final TextStyle style = cell.textStyleBuilder(const <Attribution>{});
        double widest = 0;
        for (final String line in cell.text.toPlainText().split('\n')) {
          final TextPainter painter = TextPainter(
            text: TextSpan(text: line, style: style),
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout();
          widest = math.max(widest, painter.maxIntrinsicWidth);
          painter.dispose();
        }
        desired[c] = math.max(
          desired[c],
          widest + cell.padding.horizontal,
        );
      }
    }

    final double total =
        desired.fold<double>(0, (double sum, double w) => sum + w);
    List<double> widths = desired;
    if (available > 0 && total > available) {
      final double scale = available / total;
      widths = <double>[for (final double w in desired) w * scale];
    }
    if (available > 0) {
      widths = <double>[for (final double w in widths) math.min(w, available)];
    }
    _contentWidthsKey = key;
    _contentWidthsCache = widths;
    return widths;
  }

  void _handleHover(PointerHoverEvent event) {
    if (!_editable) {
      return;
    }
    if (_pointerOnToolbar(event.position)) {
      return;
    }
    final (int, int)? cell = _cellAt(event.position);
    // 指针进入右上角工具条 / 表格外的空白时不要清空：清空会让工具条
    // 在鼠标移向按钮的半路上消失，点击就落空（「操作没作用在指定位置」）。
    if (cell == null) {
      return;
    }
    if (cell.$1 == _hoverRow && cell.$2 == _hoverColumn) {
      return;
    }
    setState(() {
      _hoverRow = cell.$1;
      _hoverColumn = cell.$2;
    });
  }

  /// 表格右上角的浮动工具条：插入 / 删除行列（Typora 的表格工具条）。
  Widget _buildHoverBar(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    final int row = _hoverRow!;
    final int columns = widget.viewModel.cells[row].length;
    return Material(
      color: Colors.transparent,
      child: Container(
        height: 26,
        decoration: BoxDecoration(
          color: colors.page,
          borderRadius: BorderRadius.circular(AppRadius.block),
          border: Border.all(color: colors.chipBorder, width: 0.5),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.16),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _HoverAction(
              label: '＋行',
              tooltip: '在下方插入行（⌘↩）',
              onTap: () => _runStructure(TableCellAction.insertRowBelow),
            ),
            _HoverAction(
              label: '＋列',
              tooltip: '在右侧插入列',
              onTap: () => _runStructure(TableCellAction.insertColumnRight),
            ),
            _HoverAction(
              label: '−行',
              tooltip: '删除本行',
              enabled: row > 0,
              onTap: () => _runStructure(TableCellAction.deleteRow),
            ),
            _HoverAction(
              label: '−列',
              tooltip: '删除本列',
              enabled: columns > 1,
              onTap: () => _runStructure(TableCellAction.deleteColumn),
            ),
            // Typora 的表格工具条上就是对齐按钮（左 / 中 / 右）。
            Container(
              width: 0.5,
              height: 14,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              color: colors.chipBorder,
            ),
            _HoverAction(
              label: '左',
              tooltip: '本列左对齐',
              onTap: () => _runAlign('left'),
            ),
            _HoverAction(
              label: '中',
              tooltip: '本列居中',
              onTap: () => _runAlign('center'),
            ),
            _HoverAction(
              label: '右',
              tooltip: '本列右对齐',
              onTap: () => _runAlign('right'),
            ),
          ],
        ),
      ),
    );
  }

  /// 工具条上的整列对齐：作用在**光标所在列**（没有光标时用悬停列）。
  ///
  /// 之前用悬停列：鼠标从格子移到右上角工具条时会经过别的列，对齐就落到
  /// 最后一列（用户反馈「点某列居中，最后一列变了」）。
  void _runAlign(String align) {
    final int? column = _editColumn ?? _cursorColumn ?? _hoverColumn;
    if (column == null) {
      return;
    }
    if (_editRow != null) {
      _commitEditing();
    }
    widget.onColumnAlign?.call(widget.viewModel.nodeId, column, align);
  }

  /// 工具条执行结构操作：同样以光标所在格为准（没有光标时用悬停格）。
  void _runStructure(TableCellAction action) {
    final int? row = _editRow ?? _cursorRow ?? _hoverRow;
    final int? column = _editColumn ?? _cursorColumn ?? _hoverColumn;
    if (row == null || column == null) {
      return;
    }
    if (_editRow != null) {
      _commitEditing();
    }
    widget.onCellStructure?.call(
      widget.viewModel.nodeId,
      action,
      row,
      column,
    );
  }

  // ---------------------------------------------------------------------------
  // 渲染
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final Widget table = _buildInteractiveTable(context);
    if (widget.fillWidth) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(width: double.infinity, child: table),
      );
    }
    return SingleAxisTrackpadAndWheelScroller(
      axis: Axis.horizontal,
      controller: _scrollController,
      child: Align(
        // Typora 的表格按内容宽度靠左排，不居中、不强制铺满。
        alignment: Alignment.centerLeft,
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

  Widget _buildInteractiveTable(BuildContext context) {
    // MouseRegion 必须包住工具条：否则指针移到工具条上会触发表格的
    // onExit，工具条刚出现就消失。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double available = constraints.maxWidth;
        // 列宽始终按内容自适应（Typora 的 auto 布局），不支持拖动。
        final List<double> widths = _contentWidths(available);
        return MouseRegion(
          cursor: SystemMouseCursors.basic,
          hitTestBehavior: HitTestBehavior.translucent,
          onHover: _handleHover,
          onExit: (_) {
            if (_hoverRow != null) {
              setState(() {
                _hoverRow = null;
                _hoverColumn = null;
              });
            }
          },
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _handlePointerDown,
                onPointerMove: _handlePointerMove,
                onPointerUp: _handlePointerUp,
                onPointerCancel: _handlePointerUp,
                child: IgnorePointer(
                  ignoring: _editRow == null,
                  child: BoxComponent(
                    key: widget.componentKey,
                    opacity: widget.viewModel.opacity,
                    child: _buildTable(context, widths),
                  ),
                ),
              ),
              // 工具条只在悬停/编辑时出现，盖在表格右上角。
              if (_editable && _hoverRow != null)
                Positioned(
                  top: 2,
                  right: 2,
                  child: KeyedSubtree(
                    key: _toolbarKey,
                    child: _buildHoverBar(context),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTable(BuildContext context, List<double> widths) {
    final List<List<MarkdownTableCellViewModel>> cells = widget.viewModel.cells;
    return Table(
      border: widget.viewModel.border ?? TableBorder.all(),
      defaultColumnWidth: widget.viewModel.columnWidth,
      columnWidths: <int, TableColumnWidth>{
        for (var i = 0; i < widths.length; i++)
          i: FixedColumnWidth(widths[i]),
      },
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
              // 占位文本跟随输入内容重排：单元格高度随编辑内容增长，
              // 多行单元格不会把新行裁掉；透明度 0 所以看不到两份文字。
              Opacity(
                opacity: 0,
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _controller!,
                  builder: (BuildContext context, TextEditingValue value, _) {
                    return Text.rich(
                      _controller!.buildTextSpan(
                        context: context,
                        style: cell.textStyleBuilder(const <Attribution>{}),
                        withComposing: false,
                      ),
                      textAlign: cell.textAlign,
                    );
                  },
                ),
              ),
              Positioned.fill(child: _buildCellEditor(cell)),
            ],
          )
        : text;

    final Widget padded = Padding(padding: cell.padding, child: content);
    final BoxDecoration decoration = cell.decoration ?? const BoxDecoration();
    // 不做行高亮：选中/悬停整行变底色在长表里很像「整行被选中」，
    // 与 Typora 的观感不一致（用户明确要求去掉）。
    return DecoratedBox(
      decoration: decoration,
      // 锚点仅用于把指针坐标换算成行列，不影响命中测试。
      child: KeyedSubtree(key: _cellKey(row, column), child: padded),
    );
  }

  /// 单元格编辑框：无边框、无底色，与静态文字同字号同内边距。
  ///
  /// Typora 的表格是「文字里直接出现光标」，不是一个浮在上面的输入框；
  /// 所以这里只保留透明输入区，视觉差异只有光标和选区。
  Widget _buildCellEditor(MarkdownTableCellViewModel cell) {
    final TextStyle style = cell.textStyleBuilder(const <Attribution>{});
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      style: style,
      // 强制行盒与静态文本一致：否则进入编辑的一瞬间行高变化，整张表
      // 会上下抖一下。
      strutStyle: StrutStyle.fromTextStyle(style, forceStrutHeight: true),
      textAlign: cell.textAlign,
      cursorColor: widget.cursorColor,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      // 不挂 onTapOutside：点工具条时按钮不请求焦点，编辑态应当保留
      // （Typora 里点表格工具条不会结束单元格编辑）；点击正文由焦点
      // 监听负责提交。
      decoration: const InputDecoration(
        isDense: true,
        border: InputBorder.none,
        contentPadding: EdgeInsets.zero,
        counterText: '',
      ),
    );
  }
}

/// 单元格编辑控制器：编辑时也保留行内样式（Typora 是所见即所得）。
///
/// 输入框里的文本始终是纯文本，这里按「公共前缀 / 后缀」把它映射回原来
/// 的 [AttributedText]：没改动的字符沿用原属性，新插入的字符继承插入点
/// 的属性 —— 在粗体中间打字仍然是粗体。
class _CellTextController extends TextEditingController {
  _CellTextController({
    required AttributedText source,
    required TextStyle Function(Set<Attribution>) styleBuilder,
  })  : _source = source,
        _styleBuilder = styleBuilder,
        super(text: source.toPlainText());

  final AttributedText _source;
  final TextStyle Function(Set<Attribution>) _styleBuilder;

  String get _sourceText => _source.toPlainText();

  int? _cachedPrefix;
  int? _cachedSuffix;
  String? _cachedText;

  int get _prefix {
    _recomputeDiff();
    return _cachedPrefix!;
  }

  int get _suffix {
    _recomputeDiff();
    return _cachedSuffix!;
  }

  void _recomputeDiff() {
    if (_cachedText == text && _cachedPrefix != null) {
      return;
    }
    final String original = _sourceText;
    final String current = text;
    final int max = math.min(original.length, current.length);
    var prefix = 0;
    while (prefix < max &&
        original.codeUnitAt(prefix) == current.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < max - prefix &&
        original.codeUnitAt(original.length - 1 - suffix) ==
            current.codeUnitAt(current.length - 1 - suffix)) {
      suffix++;
    }
    _cachedPrefix = prefix;
    _cachedSuffix = suffix;
    _cachedText = current;
  }

  /// 当前文本第 [index] 个字符应有的行内属性。
  Set<Attribution> _attributionsAt(int index) {
    if (_sourceText.isEmpty) {
      return const <Attribution>{};
    }
    final int prefix = _prefix;
    final int suffix = _suffix;
    int? originalIndex;
    if (index < prefix) {
      originalIndex = index;
    } else if (index >= text.length - suffix) {
      originalIndex = index + (_sourceText.length - text.length);
    }
    if (originalIndex == null) {
      // 新插入的字符：继承插入点前一个字符的样式。
      final int anchor = (prefix > 0 ? prefix - 1 : 0)
          .clamp(0, _sourceText.length - 1);
      return _source.spans.getAllAttributionsAt(anchor).toSet();
    }
    if (originalIndex < 0 || originalIndex >= _sourceText.length) {
      return const <Attribution>{};
    }
    return _source.spans.getAllAttributionsAt(originalIndex).toSet();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final String value = text;
    if (value.isEmpty) {
      return TextSpan(text: '', style: _styleBuilder(const <Attribution>{}));
    }
    // 组词区间要保留输入法的下划线（默认 TextField 的行为），否则中文
    // 输入时看不出哪些字还没上屏。
    final TextRange composing = this.value.composing;
    final bool hasComposing =
        withComposing && composing.isValid && !composing.isCollapsed;
    bool inComposing(int index) =>
        hasComposing && index >= composing.start && index < composing.end;

    final List<TextSpan> children = <TextSpan>[];
    var segmentStart = 0;
    var segmentAttributions = _attributionsAt(0);
    var segmentComposing = inComposing(0);
    for (var i = 1; i <= value.length; i++) {
      final Set<Attribution>? next =
          i < value.length ? _attributionsAt(i) : null;
      final bool nextComposing = i < value.length && inComposing(i);
      if (next == null ||
          !setEquals(next, segmentAttributions) ||
          nextComposing != segmentComposing) {
        TextStyle segmentStyle = _styleBuilder(segmentAttributions);
        if (segmentComposing) {
          segmentStyle = segmentStyle.copyWith(
            decoration: TextDecoration.underline,
          );
        }
        children.add(
          TextSpan(
            text: value.substring(segmentStart, i),
            style: segmentStyle,
          ),
        );
        if (next != null) {
          segmentStart = i;
          segmentAttributions = next;
          segmentComposing = nextComposing;
        }
      }
    }
    return TextSpan(children: children);
  }

  /// 提交时把当前纯文本连同行内属性一起写回。
  AttributedText attributedValue() {
    final String value = text;
    final AttributedText result = AttributedText(value);
    if (value.isEmpty) {
      return result;
    }
    var segmentStart = 0;
    var segmentAttributions = _attributionsAt(0);
    for (var i = 1; i <= value.length; i++) {
      final Set<Attribution>? next =
          i < value.length ? _attributionsAt(i) : null;
      if (next == null || !setEquals(next, segmentAttributions)) {
        for (final Attribution attribution in segmentAttributions) {
          result.addAttribution(
            attribution,
            SpanRange(segmentStart, i - 1),
          );
        }
        if (next == null) {
          break;
        }
        segmentStart = i;
        segmentAttributions = next;
      }
    }
    return result;
  }
}

/// 表格悬停工具条上的小按钮（26 高、11.5 号字）。
class _HoverAction extends StatelessWidget {
  const _HoverAction({
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
  });

  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final AppColors colors = AppColors.of(context);
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: AppPressable(
        enabled: enabled,
        onTap: enabled ? onTap : null,
        pressedScale: 1,
        pressedColor: AppPress.overlay(context),
        child: SizedBox(
          height: 26,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1,
                  color: enabled ? colors.text : colors.tertiary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
