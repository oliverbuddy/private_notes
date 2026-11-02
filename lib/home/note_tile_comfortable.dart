import 'dart:io';

import 'package:flutter/material.dart';

import '../editor/block.dart';
import '../editor/markdown_view.dart';
import '../models/note.dart';
import '../theme/app_theme.dart';
import '../ui/quote_block.dart';
import '../ui/tag_chip.dart';
import '../util/date_format.dart';
import '../util/text_highlight.dart';

/// 附件行：整行只有一个**本地**文件链接（`[文件名](路径)`）。
///
/// 正则与 `block.dart` 的 `_filePattern` 保持一致（行尾容忍空格 / `\r`，
/// 路径不含空白）—— 笔记文件可能被 Windows 编辑器或复制粘贴改动过，
/// 旧版就栽在「行尾多了个空格，附件不识别」上。
/// 行首允许带标题记号：老数据里出现过 `## [文件](assets/…)`（附件被插进
/// 标题行），详情页同样按附件渲染，摘要必须跟上。
final RegExp _attachmentLine =
    RegExp(r'^(?:#{1,6}[ \t]+)?\[([^\]]+)\]\(([^)\s]+)\)[ \t\r]*$');

/// 外链不是附件（http/https）。
bool _isLocalFileLink(String path) =>
    !path.startsWith('http://') && !path.startsWith('https://');

/// 舒适密度的列表行。
///
/// 这一档的信息量是「扫读」用的：最多 5 行摘要 + 缩略图 + 时间/标签。
/// 摘要必须剥掉 markdown 记号，否则每一行都以 `# ` 或 `**` 开头，像在看源码。
class NoteTileComfortable extends StatelessWidget {
  const NoteTileComfortable({
    super.key,
    required this.note,
    required this.thumbnailPaths,
    this.hiddenThumbnailCount = 0,
    this.query = '',
    this.maxSummaryLines = 5,
    required this.onTap,
    required this.onLongPress,
  });

  final Note note;

  /// 最多 3 个绝对路径。
  final List<String> thumbnailPaths;

  /// 超过 3 张时，第三张上盖 `+N`。
  final int hiddenThumbnailCount;

  final String query;

  /// 浏览时 5 行，搜索时压到 2 行 —— 结果多时更需要一屏看到更多条目。
  final int maxSummaryLines;

  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final summary = plainSummary(note.body);

    // 与详情页完全同一套正文：15.5 / 1.7 / 字距 0.3。
    final summaryStyle = TextStyle(
      fontSize: 15.5,
      height: 1.7,
      letterSpacing: 0.3,
      leadingDistribution: TextLeadingDistribution.even,
      color: colors.text,
    );

    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 0),
      // 外层间距由列表负责（含卡间 10），这里只做卡片本体。
      child: Material(
        // 深色下卡片用 pageAlt（比底色亮一档），与设置页的白卡处理一致。
        color: isDark ? colors.pageAlt : colors.page,
        borderRadius: BorderRadius.circular(AppRadius.card + 2),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (summary.isEmpty)
                  Text(
                    '（无正文）',
                    style: summaryStyle.copyWith(color: colors.tertiary),
                  )
                else
                // 摘要用和详情页同一套 markdown 渲染，标题、加粗、列表在列表里
                // 就已经是最终的样子 —— 否则点进去会像换了一篇东西。
                // 引用单独按块渲染：详情里引用是「整块浅底 + 左竖条」，
                // TextSpan 的逐行底色做不出这个形状，所以摘要也按行分组。
                // 只有搜索时退回纯文本，因为要按关键字高亮。
                if (query.isEmpty)
                  _SummaryMarkdown(
                    source: excerptSource(
                      note.body,
                      maxLines: maxSummaryLines,
                    ),
                    style: summaryStyle,
                    colors: colors,
                    headingBoost: 0.86,
                    maxLines: maxSummaryLines,
                  )
                else
                  Text.rich(
                    TextSpan(
                      children: highlightSpans(
                        text: summary,
                        query: query,
                        style: summaryStyle,
                        highlightColor: colors.searchHit,
                      ),
                    ),
                    maxLines: maxSummaryLines,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (thumbnailPaths.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      for (var i = 0; i < thumbnailPaths.length; i++)
                        Padding(
                          padding: EdgeInsets.only(
                            right: i == thumbnailPaths.length - 1 ? 0 : 6,
                          ),
                          child: _Thumbnail(
                            path: thumbnailPaths[i],
                            overlayCount: (i == thumbnailPaths.length - 1 &&
                                    hiddenThumbnailCount > 0)
                                ? hiddenThumbnailCount
                                : 0,
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                _MetaRow(note: note),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 摘要的块级渲染：引用按「整块浅底 + 左竖条」渲染，和详情页一致。
///
/// 普通行仍交给 [markdownSpans]（标题/列表/标签/加粗都在里面），
/// 只有遇到 `>` 行时切成独立的引用块。摘要最多 5~6 行，按块分开
/// 不会带来明显的布局成本，但视觉上和详情页对得上了。
class _SummaryMarkdown extends StatelessWidget {
  const _SummaryMarkdown({
    required this.source,
    required this.style,
    required this.colors,
    required this.headingBoost,
    required this.maxLines,
  });

  final String source;
  final TextStyle style;
  final AppColors colors;
  final double headingBoost;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    if (source.isEmpty) {
      return const SizedBox.shrink();
    }
    final List<_SummaryBlock> blocks = _split(source);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final block in blocks)
          if (block.isBlank)
            // 用户有意留出的空行在摘要里也要看得见：渲染成一行空隙，
            // 高度与正文行盒一致（用户反复强调不要去掉空白行）。
            SizedBox(
              height:
                  (style.fontSize ?? 15.5) * (style.height ?? 1.2),
            )
          else if (block.attachmentName != null)
            _buildAttachment(block.attachmentName!)
          else if (block.isQuote)
            _buildQuote(block.text)
          else
            Text.rich(
              TextSpan(
                children: markdownSpans(
                  block.text,
                  style,
                  colors,
                  headingBoost: headingBoost,
                ),
              ),
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
            ),
      ],
    );
  }

  /// 附件行：与详情页的附件卡片同一套语言（浅底圆角 + 文件图标 + 文件名），
  /// 只是高度压缩到摘要尺度 —— 列表里不需要「点击查看」的副标题。
  Widget _buildAttachment(String name) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(AppRadius.block),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.insert_drive_file_outlined,
            size: 16,
            color: colors.accent,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.2,
                fontWeight: AppWeight.medium,
                color: colors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 引用块：外壳与详情编辑器共用 [QuoteBlock]（连竖条圆角都一致）。
  Widget _buildQuote(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: QuoteBlock(
        child: Text.rich(
          TextSpan(
            children: markdownSpans(
              text,
              style.copyWith(
                fontSize: AppQuote.fontSize,
                height: AppQuote.height,
                letterSpacing: AppQuote.letterSpacing,
                leadingDistribution: TextLeadingDistribution.even,
                color: colors.text.withValues(alpha: 0.8),
              ),
              colors,
            ),
          ),
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// 把行分成「普通行」和「连续引用行」两组，保持原始顺序。
  List<_SummaryBlock> _split(String text) {
    final List<_SummaryBlock> blocks = <_SummaryBlock>[];
    final List<String> lines = <String>[];
    bool inQuote = false;

    void flush() {
      if (lines.isEmpty) {
        return;
      }
      blocks.add(_SummaryBlock(
        text: lines.join('\n'),
        isQuote: inQuote,
      ));
      lines.clear();
    }

    for (final line in text.split('\n')) {
      final String trimmedLeft = line.trimLeft();
      // 空行是块边界，同时保留为一处可见空隙：它之前的引用到此结束，
      // 之后的正文不属于引用（用户强调摘要里不能把空白行吃掉）。
      if (trimmedLeft.isEmpty) {
        flush();
        inQuote = false;
        // 首行是空行时不产生空隙（excerptSource 已裁掉首尾空行，
        // 这里再防一手），其余每个空行都算一行空隙。
        if (blocks.isNotEmpty) {
          blocks.add(const _SummaryBlock.blank());
        }
        continue;
      }
      // 附件行：详情页渲染成文件卡片，摘要里也必须是文件条目，
      // 不能退化成一条蓝色下划线链接（用户反馈两处不一致）。
      final RegExpMatch? attachment = _attachmentLine.firstMatch(trimmedLeft);
      if (attachment != null && _isLocalFileLink(attachment.group(2)!)) {
        flush();
        inQuote = false;
        blocks.add(_SummaryBlock.attachment(attachment.group(1)!.trim()));
        continue;
      }
      final bool hasMarker = trimmedLeft.startsWith('>');
      // 只认有 `>` 的行。super_editor 的 markdown 解析器**不实现** CommonMark
      // 的 lazy continuation（实测 `> 甲` 的下一行 `乙` 会解析成独立段落），
      // 详情页也就把它们渲染成两块；摘要跟着只认 `>`，两边才一致。
      final bool quote = hasMarker;
      if (quote != inQuote) {
        flush();
        inQuote = quote;
      }
      lines.add(
        hasMarker ? line.replaceFirst(RegExp(r'^\s*>\s?'), '') : line,
      );
    }
    flush();
    return blocks;
  }
}

class _SummaryBlock {
  const _SummaryBlock({required this.text, required this.isQuote})
      : attachmentName = null,
        isBlank = false;

  const _SummaryBlock.attachment(this.attachmentName)
      : text = '',
        isQuote = false,
        isBlank = false;

  /// 空行：渲染成一行空隙，保留用户有意留出的段落间隔。
  const _SummaryBlock.blank()
      : text = '',
        isQuote = false,
        attachmentName = null,
        isBlank = true;

  final String text;
  final bool isQuote;

  /// 附件行的文件名；非附件块为 null。
  final String? attachmentName;

  /// 是否是空行。
  final bool isBlank;
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.path, this.overlayCount = 0});

  final String path;
  final int overlayCount;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.file(
        File(path),
        width: 56,
        height: 56,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => Container(
          width: 56,
          height: 56,
          color: colors.surface2,
          alignment: Alignment.center,
          child: Icon(Icons.image_not_supported_outlined,
              size: 14, color: colors.tertiary),
        ),
      ),
    );

    if (overlayCount <= 0) {
      return image;
    }

    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          image,
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Container(
              color: const Color(0xFF000000).withValues(alpha: 0.45),
              alignment: Alignment.center,
              child: Text(
                '+$overlayCount',
                style: const TextStyle(
                  fontSize: 12,
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

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.note});

  final Note note;

  /// 卡片上最多展示的标签数：标签一多 Wrap 会折成好几行，把摘要挤出
  /// 卡片（用户实测）。多的收进「+N」，完整列表点进详情看。
  static const int _maxTags = 2;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final visibleTags = note.tags.take(_maxTags).toList();
    final overflow = note.tags.length - visibleTags.length;

    return Row(
      children: <Widget>[
        if (note.pinned)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Icon(Icons.push_pin, size: 12, color: colors.accent),
          ),
        Text(
          formatListTime(note.updated),
          style: AppText.meta.copyWith(color: colors.tertiary),
        ),
        if (visibleTags.isNotEmpty) ...<Widget>[
          const SizedBox(width: 10),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                for (final tag in visibleTags) TagChip(label: tag),
                if (overflow > 0)
                  TagChip(label: '+$overflow', isOverflow: true),
              ],
            ),
          ),
        ],
      ],
    );
  }
}


