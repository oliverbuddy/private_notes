import 'package:flutter/painting.dart';

/// 把 [query] 在 [text] 里的每一处命中包成带底色的 span。
///
/// 只加底色、不改颜色也不加粗 —— 搜索结果里颜色一旦变化，
/// 整屏会花掉，用户反而看不出哪段是命中。
List<TextSpan> highlightSpans({
  required String text,
  required String query,
  required TextStyle style,
  required Color highlightColor,
}) {
  final needle = query.trim();
  if (needle.isEmpty) {
    return <TextSpan>[TextSpan(text: text, style: style)];
  }

  final loweredText = text.toLowerCase();
  final loweredNeedle = needle.toLowerCase();
  final spans = <TextSpan>[];
  var cursor = 0;

  while (cursor < text.length) {
    final hit = loweredText.indexOf(loweredNeedle, cursor);
    if (hit < 0) {
      spans.add(TextSpan(text: text.substring(cursor), style: style));
      break;
    }
    if (hit > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, hit), style: style));
    }
    final end = hit + needle.length;
    spans.add(
      TextSpan(
        text: text.substring(hit, end),
        style: style.copyWith(backgroundColor: highlightColor),
      ),
    );
    cursor = end;
  }

  if (spans.isEmpty) {
    spans.add(TextSpan(text: text, style: style));
  }
  return spans;
}
