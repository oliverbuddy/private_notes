import 'package:flutter/material.dart';

import '../editor/block.dart';
import '../models/note.dart';
import '../theme/app_theme.dart';
import '../util/date_format.dart';
import '../util/text_highlight.dart';

/// 紧凑密度的列表行。
///
/// **单行取首行**（定稿逻辑）：一行一条，时间右对齐。
/// 观感上的关键是底色：紧凑档整个列表铺 `colors.page`（浅色=白），
/// 近黑正文压在白底上才清晰 —— 之前直接坐在 pageAlt 米底上，
/// 文字和背景融成一片，整列看着发灰。时间用 secondary 而不是
/// tertiary（tertiary 在米/深底上都快看不见了）。
/// 不显示缩略图和标签：这一档的唯一目标是**扫标题**。
class NoteTileCompact extends StatelessWidget {
  const NoteTileCompact({
    super.key,
    required this.note,
    this.query = '',
    required this.onTap,
    required this.onLongPress,
  });

  final Note note;
  final String query;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    // 只取**首行**：把后续段落压成一行再截断，会让每条看起来
    // 都以「第一句的后半截」开头，扫读时反而更慢。
    // 锁定笔记内存里没有正文，直接显示「已锁定」。
    final summary = note.locked
        ? '已锁定'
        : plainSummary(note.body).split('\n').first.trim();
    final style = TextStyle(
      fontSize: 15.5,
      height: 1.4,
      color: colors.text,
      fontWeight: AppWeight.regular,
    );

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.page,
          vertical: 14,
        ),
        child: Row(
          children: <Widget>[
            if (note.pinned)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(Icons.push_pin, size: 12, color: colors.accent),
              ),
            if (note.locked)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(Icons.lock_outline, size: 12, color: colors.secondary),
              ),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: highlightSpans(
                    text: summary.isEmpty ? '（无正文）' : summary,
                    query: query,
                    style: summary.isEmpty
                        ? style.copyWith(color: colors.secondary)
                        : style,
                    highlightColor: colors.searchHit,
                  ),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              formatListTime(note.updated),
              style: AppText.meta.copyWith(color: colors.secondary),
            ),
          ],
        ),
      ),
    );
  }
}
