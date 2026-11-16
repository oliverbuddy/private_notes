import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 列表卡片里的表格预览。
///
/// 正文第一块是表格时，列表里按**详情页的观感**画一张最多 5 行 × 4 列的
/// 小表：表头淡底加粗、数据行正文色、列宽按内容分配（与详情一致，而不是
/// 等分）、内容过长在格内换行。
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
    final TextStyle textStyle = TextStyle(
      fontSize: AppFontSize.body,
      height: 1.35,
      letterSpacing: 0,
      color: colors.text,
    );
    // 列宽按内容分配：与详情页的 auto 表格一致（长文本列更宽）。
    final List<double> weights = _contentWeights(columns, textStyle);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      // 与详情页表格同一套外框：描边画在裁剪层外面 + 内容内缩 1px 再圆角
      // 裁剪。Container 的 clipBehavior 会把 ClipPath 包在 DecoratedBox
      // 内部，描边和裁剪边界重合，单元格背景会把描边整条压掉（实测
      // 看起来「没有边框、没有圆角」）。
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.block),
          border: Border.all(color: colors.dividerStrong, width: 1),
        ),
        child: Padding(
          padding: const EdgeInsets.all(1),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.block - 1),
            child: Table(
              border: TableBorder(
                horizontalInside: BorderSide(color: colors.divider, width: 0.8),
                verticalInside: BorderSide(color: colors.divider, width: 0.8),
              ),
              columnWidths: <int, TableColumnWidth>{
                for (var i = 0; i < columns; i++)
                  i: FlexColumnWidth(weights[i]),
              },
              children: <TableRow>[
                for (var row = 0; row < rows.length; row++)
                  TableRow(
                    decoration: BoxDecoration(
                      // 与编辑器表头同一套：浅色下 surface2 与 pageAlt 同色，
                      // 深色下 surface2 比页面亮一档，不会变成纯黑条。
                      color: row == 0 ? colors.surface2 : null,
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
                            style: textStyle.copyWith(
                              fontWeight: row == 0
                                  ? AppWeight.semibold
                                  : AppWeight.regular,
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 每列的内容权重（按最长一行文字宽度，最少 1）。
  List<double> _contentWeights(int columns, TextStyle style) {
    final List<double> weights = List<double>.filled(columns, 1);
    for (final List<String> row in rows) {
      for (var c = 0; c < row.length && c < columns; c++) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: row[c], style: style),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        weights[c] = math.max(weights[c], painter.maxIntrinsicWidth);
        painter.dispose();
      }
    }
    return weights;
  }
}
