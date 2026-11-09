import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/note_image_share.dart';

void main() {
  testWidgets('分享长图：整篇笔记离屏渲染为 1080px 宽的 PNG', (WidgetTester tester) async {
    final Uint8List? bytes = await tester.runAsync(() {
      return renderNoteShareImagePng(
        markdown: '# 标题\n\n'
            '正文第一段，包含**加粗**、*斜体* 与 `行内代码`。\n\n'
            '- 一级列表\n'
            '  - 二级列表\n\n'
            '> 引用一段\n\n'
            '```dart\nvoid main() {}\n```\n\n'
            '![坏图](/missing/image.png)',
        tags: const <String>['工作', '随笔'],
        created: DateTime(2026, 11, 10),
        resolveImagePath: (String url) => '/missing/image.png',
      );
    });

    expect(bytes, isNotNull);
    final Uint8List png = bytes!;
    // PNG 文件头。
    expect(
      png.sublist(0, 8),
      <int>[137, 80, 78, 71, 13, 10, 26, 10],
    );

    final ui.Image? image = await tester.runAsync(() async {
      final ui.Codec codec = await ui.instantiateImageCodec(png);
      final ui.FrameInfo frame = await codec.getNextFrame();
      return frame.image;
    });
    expect(image, isNotNull);
    // 540 逻辑宽 × 2 倍率。
    expect(image!.width, 1080);
    // 图片块缺失时跳过，但正文本身必须撑起合理高度（约 500 逻辑高 → 1000px）。
    expect(image.height, greaterThan(800));
    image.dispose();
  });
}
