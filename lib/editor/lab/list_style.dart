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
  ///
  /// 26 → 30：勾选框右缘与正文之间至少留 6dp，否则框贴着第一个字，
  /// 待办行看起来糊成一团（用户反馈「勾选框和文字太挤」）。三种记号
  /// （圆点/编号/勾选框）仍统一用这个列宽，正文左缘保持对齐。
  static const double columnWidth = 30;

  /// 每加深一层的增量（dp）。
  static const double indentStep = 20;

  /// 勾选框边长（dp）。与 4dp 圆点的视觉重量相当，但更易点中。
  static const double checkboxSize = 20;

  /// 勾选框距记号列右缘的留白。
  ///
  /// 20dp 的框放在 30dp 列里、右缘留 6dp → 正文起点 30dp 处与框之间
  /// 正好 6dp 呼吸（[TaskCheckBox.gap] 同值）。
  static const double checkboxRightInset = 6;

  /// 记号列宽：首层 [columnWidth]，每层再加 [indentStep]。
  ///
  /// 签名与 super_editor 的 `TextBlockIndentCalculator` 一致，可直接作为
  /// `indentCalculator` 传入官方组件。
  static double width(TextStyle textStyle, int indent) =>
      columnWidth + indentStep * indent;
}
