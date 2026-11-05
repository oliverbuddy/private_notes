import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:super_editor/super_editor.dart';

import '../../theme/app_theme.dart';
import '../../ui/tag_palette.dart';

/// 正文里的 `#标签` 使用的渲染标记。
///
/// 只用于「显示」：序列化器不认识它，落盘时会被忽略；编辑文本时
/// AttributedText 会带着它一起平移，所以标签内容改了颜色/胶囊也跟着走。
class TagAttribution implements Attribution {
  const TagAttribution();

  @override
  String get id => 'xiaoji-tag';

  @override
  bool canMergeWith(Attribution other) => other is TagAttribution;

  @override
  bool operator ==(Object other) => other is TagAttribution;

  @override
  int get hashCode => id.hashCode;
}

/// `#标签` 的匹配规则。和旧阅读态渲染器保持一致：
/// `#` 后面不能是空白、`#` 或常见中文标点；不能匹配标题的 `# `。
final RegExp _tagPattern =
    RegExp(r'#[^\s#，。！？、,.!?]+');

/// 给文档里所有 `#标签` 打上 [TagAttribution]。
///
/// 每次文本变化后调用（在编辑器的 change listener 里、同一帧内），
/// 这样新输入的标签也能立刻变成胶囊；attributes 只影响显示，
/// 不改变落盘内容。
void applyTagAttributions(MutableDocument document) {
  for (final node in document) {
    if (node is! TextNode) {
      continue;
    }
    final text = node.text;
    final int length = text.length;
    if (length == 0) {
      continue;
    }

    final Set<AttributionSpan> existing = text.getAttributionSpansInRange(
      attributionFilter: (Attribution attribution) =>
          attribution is TagAttribution,
      range: SpanRange(0, length - 1),
    );

    final List<AttributionSpan> desired = <AttributionSpan>[];
    for (final match in _tagPattern.allMatches(text.toPlainText())) {
      final int start = match.start;
      // 代码、链接里的 `#` 不是标签（例如 `#include` / URL 锚点）。
      final attributionsAtStart = text.spans.getAllAttributionsAt(start);
      if (attributionsAtStart.contains(codeAttribution) ||
          attributionsAtStart.any((Attribution a) => a is LinkAttribution)) {
        continue;
      }
      desired.add(AttributionSpan(
        attribution: const TagAttribution(),
        start: start,
        end: match.end - 1,
      ));
    }

    if (_sameSpans(existing, desired)) {
      continue;
    }

    // 先整段摘掉再重打：标签数量少，比逐段 diff 更稳，也不会留下
    // 半个旧标签（编辑到一半时最容易出现）。
    text.removeAttribution(const TagAttribution(), SpanRange(0, length - 1));
    for (final span in desired) {
      text.addAttribution(
        span.attribution,
        SpanRange(span.start, span.end),
      );
    }
  }
}

bool _sameSpans(Set<AttributionSpan> existing, List<AttributionSpan> desired) {
  if (existing.length != desired.length) {
    return false;
  }
  for (final want in desired) {
    final matched = existing.any(
      (AttributionSpan have) =>
          have.start == want.start && have.end == want.end,
    );
    if (!matched) {
      return false;
    }
  }
  return true;
}

/// 把标签胶囊画在正文下面的一层。
///
/// super_editor 的 `TextStyle` 只能给文字铺矩形底色，圆角胶囊必须
/// 用内容层画。这里照着官方 `AttributionBounds` 的做法，按标签的
/// DocumentRange 取文字矩形，再把矩形左右各外扩 4、上下收 2 画出胶囊。
class TagChipsUnderlayBuilder implements SuperEditorLayerBuilder {
  const TagChipsUnderlayBuilder();

  @override
  ContentLayerWidget build(BuildContext context, SuperEditorContext editContext) {
    return _TagChips(
      document: editContext.document,
      layout: editContext.documentLayout,
    );
  }
}

class _TagChips extends ContentLayerStatefulWidget<List<_TagChipLayout>> {
  const _TagChips({required this.document, required this.layout});

  final Document document;
  final DocumentLayout layout;

  @override
  ContentLayerState<_TagChips, List<_TagChipLayout>> createState() =>
      _TagChipsState();
}

class _TagChipsState
    extends ContentLayerState<_TagChips, List<_TagChipLayout>> {
  @override
  void initState() {
    super.initState();
    widget.document.addListener(_onDocumentChanged);
  }

  @override
  void dispose() {
    widget.document.removeListener(_onDocumentChanged);
    super.dispose();
  }

  void _onDocumentChanged(DocumentChangeLog changeLog) {
    if (!mounted) {
      return;
    }
    setState(() {});
    // 文档变更通知先于「编辑器 change listener」发出，此时标签属性
    // 还没补打上（applyTagAttributions 在后者里跑）。下一帧再算一次，
    // 新输入的 `#标签` 才能在输入当下就长出胶囊，而不是等重开笔记。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  List<_TagChipLayout>? computeLayoutData(
    Element? contentElement,
    RenderObject? contentLayout,
  ) {
    final chips = <_TagChipLayout>[];
    for (final node in widget.document) {
      if (node is! TextNode || node.text.length == 0) {
        continue;
      }
      final spans = node.text.getAttributionSpansInRange(
        attributionFilter: (Attribution attribution) =>
            attribution is TagAttribution,
        range: SpanRange(0, node.text.length - 1),
      );
      for (final span in spans) {
        final rect = widget.layout.getRectForSelection(
          DocumentPosition(
            nodeId: node.id,
            nodePosition: TextNodePosition(offset: span.start),
          ),
          DocumentPosition(
            nodeId: node.id,
            nodePosition: TextNodePosition(offset: span.end + 1),
          ),
        );
        if (rect != null) {
          // 胶囊颜色按标签名取固定色（与列表/详情底部同一套 [TagPalette]）。
          final String label = node.text.toPlainText().substring(
                span.start,
                span.end + 1,
              );
          chips.add(_TagChipLayout(rect, label: label));
        }
      }
    }
    return chips;
  }

  @override
  Widget doBuild(BuildContext context, List<_TagChipLayout>? layoutData) {
    if (layoutData == null) {
      return const SizedBox.shrink();
    }
    final colors = AppColors.of(context);
    return IgnorePointer(
      child: Stack(
        children: <Widget>[
          for (final chip in layoutData)
            Positioned.fromRect(
              rect: _chipRect(chip.rect),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: TagPalette.toneFor(chip.label, colors).background,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: TagPalette.toneFor(chip.label, colors).border,
                    width: 0.5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 文字行盒 24px，胶囊做 20px 高、左右各外扩 4px：
  /// 太贴字形会像高亮，太松又会跨到相邻字。
  Rect _chipRect(Rect textRect) {
    final double height = math.min(20.0, textRect.height - 4);
    final double top = textRect.top + (textRect.height - height) / 2;
    return Rect.fromLTRB(
      textRect.left - 4,
      top,
      textRect.right + 4,
      top + height,
    );
  }
}

class _TagChipLayout {
  const _TagChipLayout(this.rect, {required this.label});

  final Rect rect;

  /// 标签文字（含 `#`），用来取固定配色。
  final String label;
}
