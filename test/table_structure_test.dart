import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';
import 'package:xiaoji/editor/lab/table_cell_editor.dart';

/// 桌面表格的结构操作：插入 / 删除行列（纯函数，便于单测）。
void main() {
  TableBlockNode table(List<List<String>> rows) {
    return TableBlockNode(
      id: 't1',
      cells: <List<TextNode>>[
        for (final List<String> row in rows)
          <TextNode>[
            for (final String cell in row)
              TextNode(id: Editor.createNodeId(), text: AttributedText(cell)),
          ],
      ],
    );
  }

  List<List<String>> texts(TableBlockNode node) => <List<String>>[
        for (int r = 0; r < node.rowCount; r++)
          <String>[
            for (int c = 0; c < node.columnCount; c++)
              node.getCell(rowIndex: r, columnIndex: c).text.toPlainText(),
          ],
      ];

  final TableBlockNode sample = table(<List<String>>[
    <String>['名称', '数量'],
    <String>['苹果', '3'],
  ]);

  test('下方插入行：新行落在目标行之后且为空', () {
    final TableBlockNode? next =
        rebuildTableNode(sample, TableCellAction.insertRowBelow, 1, 0);
    expect(texts(next!), <List<String>>[
      <String>['名称', '数量'],
      <String>['苹果', '3'],
      <String>['', ''],
    ]);
  });

  test('上方插入行', () {
    final TableBlockNode? next =
        rebuildTableNode(sample, TableCellAction.insertRowAbove, 1, 0);
    expect(texts(next!)[1], <String>['', '']);
    expect(texts(next)[2], <String>['苹果', '3']);
  });

  test('左右插入列', () {
    final TableBlockNode left =
        rebuildTableNode(sample, TableCellAction.insertColumnLeft, 0, 1)!;
    expect(texts(left).first, <String>['名称', '', '数量']);
    final TableBlockNode right =
        rebuildTableNode(sample, TableCellAction.insertColumnRight, 0, 0)!;
    expect(texts(right).first, <String>['名称', '', '数量']);
  });

  test('删除数据行；表头行不能删', () {
    final TableBlockNode? next =
        rebuildTableNode(sample, TableCellAction.deleteRow, 1, 0);
    expect(next!.rowCount, 1);
    expect(
      rebuildTableNode(sample, TableCellAction.deleteRow, 0, 0),
      isNull,
    );
  });

  test('删除列；最后一列不能删', () {
    final TableBlockNode? next =
        rebuildTableNode(sample, TableCellAction.deleteColumn, 0, 1);
    expect(texts(next!).first, <String>['名称']);
    expect(
      rebuildTableNode(next, TableCellAction.deleteColumn, 0, 0),
      isNull,
    );
  });

  test('越界行列返回 null', () {
    expect(
      rebuildTableNode(sample, TableCellAction.insertRowAbove, 9, 0),
      isNull,
    );
    expect(
      rebuildTableNode(sample, TableCellAction.insertColumnLeft, 0, 9),
      isNull,
    );
  });
}
