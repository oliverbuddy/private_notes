import 'dart:io';

import 'package:flutter/material.dart';

import '../editor/block.dart';
import '../models/note.dart';
import '../platform/platform_features.dart';
import '../theme/app_theme.dart';
import '../ui/pressable.dart';
import '../util/date_format.dart';
import '../util/text_highlight.dart';

/// 紧凑密度的列表行。
///
/// **单行取首行**（定稿逻辑）：一行一条，时间右对齐。
/// 观感上的关键是底色：紧凑档整个列表铺 `colors.page`（浅色=白），
/// 近黑正文压在白底上才清晰 —— 之前直接坐在 pageAlt 米底上，
/// 文字和背景融成一片，整列看着发灰。时间用 secondary 而不是
/// tertiary（tertiary 在米/深底上都快看不见了）。
/// 不显示标签（这一档的唯一目标是**扫标题**），但保留一个 40dp 的
/// 首图缩略 + 图片总数；没有图但有附件时用回形针代替。
class NoteTileCompact extends StatelessWidget {
  const NoteTileCompact({
    super.key,
    required this.note,
    this.query = '',
    this.thumbnailPaths = const <String>[],
    this.imageCount = 0,
    this.hasAttachment = false,
    required this.onTap,
    required this.onLongPress,
  });

  final Note note;
  final String query;

  /// 最多取第一张，紧凑档只放一个 40dp 的方块。
  final List<String> thumbnailPaths;

  /// 正文里的图片总数，用来在缩略图上盖 `+N`。
  final int imageCount;

  final bool hasAttachment;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    // 只取**首行**：把后续段落压成一行再截断，会让每条看起来
    // 都以「第一句的后半截」开头，扫读时反而更慢。
    // 锁定笔记内存里没有正文，直接显示「已锁定」。
    final summary =
        note.locked ? '已锁定' : plainSummary(note.body).split('\n').first.trim();
    final style = TextStyle(
      fontSize: AppFontSize.summary,
      height: 1.4,
      color: colors.text,
      fontWeight: AppWeight.regular,
    );

    // 只有图片/附件、没有文字时把媒体挪到行首：
    // 否则左侧空一大块、内容挤在最右边，看起来像少了一条。
    final Widget? media = thumbnailPaths.isNotEmpty
        ? _CompactThumbnail(
            path: thumbnailPaths.first,
            hiddenCount: (imageCount - 1).clamp(0, 99),
          )
        : hasAttachment
            ? Icon(Icons.attach_file_rounded,
                size: AppIcon.inline, color: colors.secondary)
            : null;
    final bool leadMedia = media != null && summary.isEmpty;

    return AppPressable(
      onTap: onTap,
      onLongPress: onLongPress,
      // 桌面端右键 = 移动端长按：同一份动作菜单，不另做一套。
      onSecondaryTap: PlatformFeatures.isDesktop ? onLongPress : null,
      // 整行蒙层：文字不淡出，按下去是「这一行变灰」。
      pressedColor: AppPress.overlay(context),
      pressedOpacity: 1,
      pressedScale: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.page,
          vertical: 12,
        ),
        child: Row(
          children: <Widget>[
            if (note.pinned)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(Icons.push_pin_rounded,
                    size: AppIcon.badge, color: colors.accent),
              ),
            if (note.locked)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child:
                    Icon(Icons.lock_outline_rounded,
                        size: AppIcon.badge, color: colors.secondary),
              ),
            if (leadMedia) ...<Widget>[
              media,
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: highlightSpans(
                    // 有图片/附件时不再写「（无正文）」：与舒适档一致，
                    // 右侧的缩略图本身就是内容。
                    text: summary.isEmpty
                        ? ((thumbnailPaths.isEmpty && !hasAttachment)
                            ? '（无正文）'
                            : '')
                        : summary,
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
            if (!leadMedia && media != null) ...<Widget>[
              const SizedBox(width: 10),
              media,
            ],
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

/// 紧凑档的单张缩略图：40dp 方格，多图时右下角盖 `+N`。
class _CompactThumbnail extends StatelessWidget {
  const _CompactThumbnail({required this.path, required this.hiddenCount});

  final String path;
  final int hiddenCount;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    // 40 而不是 44：行高 = 40 + 上下各 12 = 64，正好落在双行列表刻度上。
    const double size = 40;
    final Widget image = ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.thumb),
      child: Image.file(
        File(path),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => Container(
          width: size,
          height: size,
          color: colors.surface2,
          alignment: Alignment.center,
          child: Icon(
            Icons.image_not_supported_outlined,
            size: AppIcon.inline,
            color: colors.tertiary,
          ),
        ),
      ),
    );
    if (hiddenCount <= 0) {
      return image;
    }
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          image,
          Align(
            alignment: Alignment.bottomRight,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFF000000).withValues(alpha: 0.55),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  bottomRight: Radius.circular(AppRadius.thumb),
                ),
              ),
              child: Text(
                '+$hiddenCount',
                style: const TextStyle(
                  fontSize: AppFontSize.tiny,
                  height: 1.1,
                  color: Color(0xFFFFFFFF),
                  fontWeight: AppWeight.medium,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
