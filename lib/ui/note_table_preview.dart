import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 列表卡片里的迷你表格预览。
///
/// 详情正文第一块是表格时，列表里只给一行压平的摘要完全看不出是表格
/// （用户反馈）。这里按详情页的「轻网格」观感画一张最多 3 行 × 4 列的
/// 小表：表头淡底加粗、数据行正文色，超出的单元格省略号截断。
class NoteTablePreview extends StatelessWidget {
  const NoteTablePreview({
    super.key,
    required this.rows,
    this.maxWidth = 460,
  });

  /// 第一行是表头，其余是数据行；每行列数可以不同（缺的补空）。
  final List<List<String>> rows;

  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }
    final AppColors colors = AppColors.of(context);
    final int columns = rows.fold<int>(
      1,
      (int max, List<String> row) => row.length > max ? row.length : max,
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Table(
        border: TableBorder.all(color: colors.divider, width: 0.6),
        defaultColumnWidth: const FlexColumnWidth(),
        children: <TableRow>[
          for (var row = 0; row < rows.length; row++)
            TableRow(
              decoration: BoxDecoration(
                color: row == 0 ? colors.pageAlt : null,
              ),
              children: <Widget>[
                for (var column = 0; column < columns; column++)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    child: Text(
                      column < rows[row].length ? rows[row][column] : '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppFontSize.caption,
                        height: 1.2,
                        color: colors.text,
                        fontWeight:
                            row == 0 ? AppWeight.semibold : AppWeight.regular,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
