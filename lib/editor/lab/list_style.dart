import 'package:flutter/material.dart';

/// 列表 / 待办的记号列几何（详情页与列表页共用一套数值）。
///
/// 参考 GitHub / 语雀的排布：记号（圆点、编号、勾选框）占用固定宽度的一列，
/// 正文紧跟在列右缘之后，每深一层整体右移一档。super_editor 默认列宽是
/// `(fontSize * 0.6) * 4`，15.5 字号下是 37.2dp —— 编号离行头太远，
/// 且任务组件用的也是这个默认值，导致「无序/有序/待办」三种行左边对不齐。
///
/// 这里把三种行的记号列统一成同一个函数，组件与缩进命令都引用它：
///   - 无序：圆点靠列右缘；
///   - 有序：编号靠列右缘；
///   - 待办：勾选框在列内水平居中于圆点的圆心上。
/// 正文起点因此完全一致，行与行之间不会出现「有的靠左、有的缩进」。
abstract final class AppListMarker {
  /// 首层记号列宽（dp）。
  static const double columnWidth = 26;

  /// 每加深一层的增量（dp）。
  static const double indentStep = 20;

  /// 勾选框边长（dp）。与 4dp 圆点的视觉重量相当，但更易点中。
  static const double checkboxSize = 20;

  /// 勾选框距记号列右缘的留白。
  ///
  /// 圆点在 26dp 列里右缘留 10dp → 圆心落在 14dp；20dp 的框右缘留 2dp
  /// 时圆心同样落在 14dp，两类行的记号视觉轴心重合。
  static const double checkboxRightInset = 2;

  /// 记号列宽：首层 [columnWidth]，每层再加 [indentStep]。
  ///
  /// 签名与 super_editor 的 `TextBlockIndentCalculator` 一致，可直接作为
  /// `indentCalculator` 传入官方组件。
  static double width(TextStyle textStyle, int indent) =>
      columnWidth + indentStep * indent;
}
