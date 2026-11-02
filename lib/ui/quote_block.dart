import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 引用块的外壳（浅底 + 左侧竖条 + 圆角）。
///
/// 详情编辑器与列表摘要共用这一个组件：之前两边各画一套（详情用直角
/// 边框、列表用 BoxDecoration 的 left border），竖条两端有没有圆角都
/// 不一样。这里用「整体圆角裁剪 + 左侧竖条」保证两条边都是圆角。
class QuoteBlock extends StatelessWidget {
  const QuoteBlock({
    super.key,
    required this.child,
    this.continuesAbove = false,
    this.continuesBelow = false,
  });

  final Widget child;

  /// 上方 / 下方紧挨着另一个引用块。
  ///
  /// 引用块在模型里是「一行一个段落」，回车续行会拆成两个相邻的引用
  /// 段落。若各自完整地画圆角与上下内边距，中间会露出页面底色的缝，
  /// 看起来就是两个独立引用框（用户反馈）。相邻时把这一侧的圆角与
  /// 内边距省掉，两块合流成一整块连续引用（语雀同款）。
  final bool continuesAbove;
  final bool continuesBelow;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final BorderRadius radius = BorderRadius.vertical(
      top: Radius.circular(continuesAbove ? 0 : AppQuote.radius),
      bottom: Radius.circular(continuesBelow ? 0 : AppQuote.radius),
    );
    return ClipRRect(
      borderRadius: radius,
      child: Stack(
        children: <Widget>[
          Container(
            width: double.infinity,
            color: colors.surface2,
            // 内容让出竖条宽度，文字才不会压在竖条上。
            padding: EdgeInsets.fromLTRB(
              AppQuote.padHorizontal + AppQuote.barWidth,
              continuesAbove ? 0 : AppQuote.padVertical,
              AppQuote.padHorizontal,
              continuesBelow ? 0 : AppQuote.padVertical,
            ),
            child: child,
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: AppQuote.barWidth,
            child: ColoredBox(
              color: colors.secondary.withValues(alpha: 0.55),
            ),
          ),
        ],
      ),
    );
  }
}
