import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';
import 'package:xiaoji/editor/lab/table_cell_editor.dart';
import 'package:xiaoji/editor/lab/xiaoji_markdown.dart';

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

  test('单元格内换行用 <br> 往返，不会压成一行', () {
    final MutableDocument document = MutableDocument(
      nodes: <DocumentNode>[
        TableBlockNode(
          id: 't1',
          cells: <List<TextNode>>[
            <TextNode>[
              TextNode(id: 'h1', text: AttributedText('名称')),
              TextNode(id: 'h2', text: AttributedText('说明')),
            ],
            <TextNode>[
              TextNode(id: 'c1', text: AttributedText('苹果')),
              TextNode(id: 'c2', text: AttributedText('第一行\n第二行')),
            ],
          ],
        ),
      ],
    );
    final String markdown = serializeDocumentToXiaojiMarkdown(document);
    expect(markdown.contains('第一行<br>第二行'), isTrue);

    final MutableDocument parsed = deserializeXiaojiMarkdown(markdown);
    final TableBlockNode table = parsed.getNodeAt(0)! as TableBlockNode;
    expect(
      table.getCell(rowIndex: 1, columnIndex: 1).text.toPlainText(),
      '第一行\n第二行',
    );
  });

  test('列对齐写回分隔行', () {
    final MutableDocument document = MutableDocument(
      nodes: <DocumentNode>[
        TableBlockNode(
          id: 't1',
          cells: <List<TextNode>>[
            <TextNode>[
              TextNode(id: 'h1', text: AttributedText('名称')),
              TextNode(
                id: 'h2',
                text: AttributedText('数量'),
                metadata: <String, dynamic>{
                  TextNodeMetadata.textAlign: 'center',
                },
              ),
            ],
            <TextNode>[
              TextNode(id: 'c1', text: AttributedText('苹果')),
              TextNode(
                id: 'c2',
                text: AttributedText('3'),
                metadata: <String, dynamic>{
                  TextNodeMetadata.textAlign: 'center',
                },
              ),
            ],
          ],
        ),
      ],
    );
    final String markdown = serializeDocumentToXiaojiMarkdown(document);
    expect(markdown.contains(':---:'), isTrue);
  });
}
