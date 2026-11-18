import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../editor/block.dart';
import '../editor/markdown_view.dart';
import '../models/note.dart';
import '../theme/app_theme.dart';
import '../ui/local_image.dart';
import '../ui/pressable.dart';
import '../ui/note_table_preview.dart';
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
    // 锁定笔记：正文不在内存里，列表只显示明文标题与标签，不渲染摘要。
    // 正文按「文字段 / 表格段」切开后顺序渲染：有几张表格就画几张，
    // 不会出现「第一张表格之后、第二张表格被跳过」的错乱。
    final List<NotePreviewSegment> segments = note.locked
        ? const <NotePreviewSegment>[]
        : previewSegmentsOf(note.body);
    // 搜索高亮退回纯文本摘要（表格不参与关键字高亮）。
    final String plainText =
        note.locked ? '' : plainSummary(bodyWithoutTables(note.body));

    // iOS 正文 17pt / 行高 1.5。
    final summaryStyle = TextStyle(
      fontSize: AppFontSize.body,
      height: 1.5,
      letterSpacing: 0,
      leadingDistribution: TextLeadingDistribution.even,
      color: colors.text,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 0),
      // 外层间距由列表负责（含卡间 12），这里只做卡片本体。
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: colors.page,
          shape: AppShape.continuous(AppRadius.card),
          shadows: AppShadow.card,
        ),
        child: ClipPath(
          clipper: ShapeBorderClipper(
            shape: AppShape.continuous(AppRadius.card),
          ),
          child: AppPressable(
            onTap: onTap,
            onLongPress: onLongPress,
            // 卡片不缩放，整块轻微压暗/提亮（鸿蒙卡片的按压手感）；
            // 用蒙层而不是整体降透明度：正文和缩略图不会跟着闪。
            pressedScale: 1,
            pressedOpacity: 1,
            pressedColor: AppPress.overlay(context),
            child: Padding(
              // 窄屏卡片内边距收一档（16→14）：正文多出 4dp，
              // 320dp 机型一行能少折一次；常规宽度保持 16。
              padding: EdgeInsets.fromLTRB(
                MediaQuery.sizeOf(context).width < 360 ? 14 : AppSpace.lg,
                14,
                MediaQuery.sizeOf(context).width < 360 ? 14 : AppSpace.lg,
                14,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (note.locked)
                    Row(
                      children: <Widget>[
                        Icon(Icons.lock_outline_rounded,
                            size: AppIcon.badge, color: colors.tertiary),
                        const SizedBox(width: 6),
                        // 锁定笔记只露明文标题（锁定瞬间从首行生成），
                        // 正文与缩略图都不显示；旧数据没有标题时回落到「已锁定」。
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: highlightSpans(
                                text: note.title.isEmpty ? '已锁定' : note.title,
                                query: query,
                                style: TextStyle(
                                  fontSize: AppFontSize.labelLg,
                                  height: 1.4,
                                  color: colors.tertiary,
                                ),
                                highlightColor: colors.searchHit,
                              ),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    )
                  else ...<Widget>[
                    if (query.isEmpty) ...<Widget>[
                      // 整卡预览严格限制在 maxSummaryLines 行以内：表格的
                      // 每一行和正文的每一行共用同一份预算，用完即止。
                      LayoutBuilder(
                        builder: (BuildContext context, BoxConstraints c) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: _previewWidgets(
                              context,
                              segments,
                              summaryStyle,
                              colors,
                              c.maxWidth,
                            ),
                          );
                        },
                      ),
                      if (segments.isEmpty && thumbnailPaths.isEmpty)
                        // 只有图片的笔记不再写「（无正文）」：下面直接就是
                        // 图片行，多一行提示会让它看起来像空笔记。
                        Text(
                          '（无正文）',
                          style: summaryStyle.copyWith(color: colors.tertiary),
                        ),
                    ] else
                      Text.rich(
                        TextSpan(
                          children: highlightSpans(
                            text: plainText,
                            query: query,
                            style: summaryStyle,
                            highlightColor: colors.searchHit,
                          ),
                        ),
                        maxLines: maxSummaryLines,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
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
                              // 只有一张图时放大到 88：仍属「小图」，但单独一张
                              // 56 的方块放在整行里会显得空。多图仍走 56 方格，
                              // 三张刚好排满一行。
                              size: thumbnailPaths.length == 1 ? 88 : 56,
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
      ),
    );
  }

  /// 按正文顺序渲染预览，整卡共用 [maxSummaryLines] 行预算。
  ///
  /// 表格的每一行和正文的每一行都从同一份预算里扣，用完即止。之前每张
  /// 表格各自占满 5 行，两张表格就撑到 10 行（用户反馈「显示内容太多」）。
  List<Widget> _previewWidgets(
    BuildContext context,
    List<NotePreviewSegment> segments,
    TextStyle style,
    AppColors colors,
    double maxWidth,
  ) {
    final List<Widget> widgets = <Widget>[];
    var remaining = math.max(0, maxSummaryLines);
    for (final NotePreviewSegment segment in segments) {
      if (remaining <= 0) {
        break;
      }
      final List<List<String>>? rows = segment.rows;
      Widget? widget;
      if (rows != null) {
        if (rows.isEmpty) {
          continue;
        }
        final List<List<String>> shown = rows.length <= remaining
            ? rows
            : rows.take(remaining).toList(growable: false);
        remaining -= shown.length;
        widget = NoteTablePreview(rows: shown);
      } else {
        final String text = excerptSource(segment.text ?? '', maxLines: remaining);
        final int lines = _measurePreviewLines(
          context,
          text,
          style,
          maxWidth,
          remaining,
        );
        if (lines <= 0) {
          continue;
        }
        remaining -= lines;
        widget = _SummaryMarkdown(
          source: text,
          style: style,
          colors: colors,
          headingBoost: 0.86,
          maxLines: lines,
        );
      }
      if (widgets.isNotEmpty) {
        widgets.add(const SizedBox(height: 10));
      }
      widgets.add(widget);
    }
    return widgets;
  }

  /// 估算一段摘要文本在 [maxWidth] 下占多少视觉行（不超过 [cap]）。
  ///
  /// 直接用原始 markdown 文本测量：`#`、`**` 只会让估算偏多，宁可少显示
  /// 一行，也不能让卡片超过 [maxSummaryLines]。
  int _measurePreviewLines(
    BuildContext context,
    String text,
    TextStyle style,
    double maxWidth,
    int cap,
  ) {
    final List<String> lines = text.split('\n');
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    if (lines.isEmpty) {
      return 0;
    }
    if (maxWidth <= 0) {
      return math.min(lines.length, cap);
    }
    final TextPainter painter = TextPainter(
      text: TextSpan(text: lines.join('\n'), style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: cap,
    )..layout(maxWidth: maxWidth);
    final int measured = painter.computeLineMetrics().length;
    painter.dispose();
    return math.max(1, math.min(measured, cap));
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
    final double lineHeight = (style.fontSize ?? 17) * (style.height ?? 1.2);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 跨块统计「实际视觉行数」：以前每个块各自 maxLines，长行折行后
        // 总量会远超上限（用户看到 8 行）。这里用 TextPainter 量出每块
        // 真实占几行，留给后面的块，最后一块用剩余行数省略号收尾。
        final TextScaler textScaler = MediaQuery.textScalerOf(context);
        int remaining = math.max(1, maxLines);
        final List<Widget> children = <Widget>[];
        for (final _SummaryBlock block in blocks) {
          if (remaining <= 0) {
            break;
          }
          if (block.isBlank) {
            children.add(SizedBox(height: lineHeight));
            remaining -= 1;
            continue;
          }
          if (block.attachmentName != null) {
            children.add(_buildAttachment(block.attachmentName!));
            remaining -= 1;
            continue;
          }
          if (block.isCode) {
            // 代码块交给阅读态组件渲染成整宽圆角卡片，与详情页一致。
            children.add(
              MarkdownBlockView(
                text: block.text,
                baseSize: style.fontSize ?? 16,
              ),
            );
            remaining -= math.max(1, block.text.split('\n').length);
            continue;
          }
          if (block.isQuote) {
            children.add(_buildQuote(block.text, remaining));
            remaining -= _measureLines(
              context,
              block.text,
              style.copyWith(
                fontSize: AppQuote.fontSize,
                height: AppQuote.height,
                letterSpacing: AppQuote.letterSpacing,
                leadingDistribution: TextLeadingDistribution.even,
              ),
              constraints.maxWidth,
              remaining,
              textScaler,
            );
            continue;
          }
          final List<InlineSpan> spans = markdownSpans(
            block.text,
            style,
            colors,
            headingBoost: headingBoost,
          );
          children.add(
            Text.rich(
              TextSpan(children: spans),
              maxLines: remaining,
              overflow: TextOverflow.ellipsis,
            ),
          );
          remaining -= _measureLines(
            context,
            block.text,
            style,
            constraints.maxWidth,
            remaining,
            textScaler,
            headingBoost: headingBoost,
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: children,
        );
      },
    );
  }

  /// 量出这一块在 [maxWidth] 下占多少视觉行（不超过 [cap]）。
  int _measureLines(
    BuildContext context,
    String text,
    TextStyle textStyle,
    double maxWidth,
    int cap,
    TextScaler textScaler, {
    double headingBoost = 0,
  }) {
    if (maxWidth <= 0) {
      return 1;
    }
    final List<InlineSpan> spans = markdownSpans(
      text,
      textStyle,
      colors,
      headingBoost: headingBoost,
    ).map(_measurableSpan).toList(growable: false);
    final TextPainter painter = TextPainter(
      text: TextSpan(children: spans),
      textDirection: Directionality.of(context),
      textScaler: textScaler,
      maxLines: cap,
    )..layout(maxWidth: maxWidth);
    final int lines = painter.computeLineMetrics().length;
    painter.dispose();
    return math.max(1, lines);
  }

  /// 测量专用：把 [WidgetSpan]（标签胶囊、待办勾选框）换成文本占位。
  ///
  /// `TextPainter` 不会为 `WidgetSpan` 计算占位尺寸，直接 layout 会抛
  /// 「dimensions != null」异常 —— release 下整张卡片会变成灰色错误块，
  /// 且错误块高度无穷大。这些小组件高度与一个空格相近，用于估算行数足够。
  InlineSpan _measurableSpan(InlineSpan span) {
    if (span is PlaceholderSpan) {
      return const TextSpan(text: ' ');
    }
    if (span is TextSpan && span.children != null) {
      return TextSpan(
        text: span.text,
        style: span.style,
        children: span.children!.map(_measurableSpan).toList(growable: false),
      );
    }
    return span;
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
            Icons.insert_drive_file_rounded,
            size: AppIcon.inline,
            color: colors.accent,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppFontSize.labelLg,
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
  Widget _buildQuote(String text, int lineBudget) {
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
          maxLines: lineBudget,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// 把行分成「普通行」「连续引用行」「代码块」三组，保持原始顺序。
  List<_SummaryBlock> _split(String text) {
    final List<_SummaryBlock> blocks = <_SummaryBlock>[];
    final List<String> lines = <String>[];
    final List<String> codeLines = <String>[];
    bool inQuote = false;
    bool inCode = false;

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

    void flushCode() {
      if (codeLines.isEmpty) {
        return;
      }
      // excerptSource 可能把闭合围栏截掉：补一个，让阅读态能正确识别。
      if (!codeLines.last.trimLeft().startsWith('```')) {
        codeLines.add('```');
      }
      blocks.add(_SummaryBlock.code(codeLines.join('\n')));
      codeLines.clear();
      inCode = false;
    }

    for (final line in text.split('\n')) {
      final String trimmedLeft = line.trimLeft();
      // 代码块：围栏内原样收集，摘要里也渲染成整宽卡片（用户反馈列表
      // 里代码块完全没有效果 —— 之前围栏被 excerptSource 直接删掉了）。
      if (trimmedLeft.startsWith('```')) {
        if (!inCode) {
          flush();
          inQuote = false;
          inCode = true;
          codeLines.add(line);
        } else {
          codeLines.add(line);
          flushCode();
        }
        continue;
      }
      if (inCode) {
        // 摘要空间有限：代码最多留 3 行，避免占满整张卡片。
        if (codeLines.length < 4) {
          codeLines.add(line);
        }
        continue;
      }
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
    flushCode();
    return blocks;
  }
}

class _SummaryBlock {
  const _SummaryBlock({required this.text, required this.isQuote})
      : attachmentName = null,
        isBlank = false,
        isCode = false;

  const _SummaryBlock.attachment(this.attachmentName)
      : text = '',
        isQuote = false,
        isBlank = false,
        isCode = false;

  /// 空行：渲染成一行空隙，保留用户有意留出的段落间隔。
  const _SummaryBlock.blank()
      : text = '',
        isQuote = false,
        attachmentName = null,
        isBlank = true,
        isCode = false;

  /// 代码块（含围栏）：交给阅读态组件渲染成整宽卡片。
  const _SummaryBlock.code(this.text)
      : isQuote = false,
        attachmentName = null,
        isBlank = false,
        isCode = true;

  final String text;
  final bool isQuote;

  /// 附件行的文件名；非附件块为 null。
  final String? attachmentName;

  /// 是否是空行。
  final bool isBlank;

  /// 是否是代码块。
  final bool isCode;
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.path, this.size = 56, this.overlayCount = 0});

  final String path;
  final double size;
  final int overlayCount;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final double radius = size >= 80 ? AppRadius.block : AppRadius.thumb;
    // 56 / 88dp 缩略图按实际显示尺寸解码，避免整张原图常驻 ImageCache。
    final int decodeExtent = localImageDecodeExtent(context, size, max: 1024);
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.file(
        File(path),
        width: size,
        height: size,
        // 只限制宽度，保持解码后的原始宽高比；同时限制高度会压扁图片。
        cacheWidth: decodeExtent,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => Container(
          width: size,
          height: size,
          color: colors.surface2,
          alignment: Alignment.center,
          child: Icon(Icons.image_not_supported_outlined,
              size: AppIcon.chip, color: colors.tertiary),
        ),
      ),
    );

    if (overlayCount <= 0) {
      return image;
    }

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          image,
          ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: Container(
              color: const Color(0xFF000000).withValues(alpha: 0.45),
              alignment: Alignment.center,
              child: Text(
                '+$overlayCount',
                style: const TextStyle(
                  fontSize: AppFontSize.caption,
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
            child: Icon(Icons.push_pin_rounded,
                size: AppIcon.badge, color: colors.accent),
          ),
        Text(
          formatListTime(note.updated),
          // 时间用 secondary：tertiary 在米底/深底上偏淡（12 号字对比不足），
          // 与紧凑档保持一致。
          style: AppText.meta.copyWith(color: colors.secondary),
        ),
        if (visibleTags.isNotEmpty) ...<Widget>[
          const SizedBox(width: 10),
          Expanded(
            child: Wrap(
              // 标签变小后间距也收一档：仍然一两个标签就收进一行，
              // 不再把摘要往下挤。
              spacing: 6,
              runSpacing: 4,
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
