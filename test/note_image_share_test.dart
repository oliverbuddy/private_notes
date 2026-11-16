import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/note_image_share.dart';

Future<void> _pumpNote(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 405,
            child: Text(
              '正文第一段，用来验证分享图直接复用详情的渲染结果。\n'
              '第二行文字，宽度和详情保持一致。',
            ),
          ),
        ),
      ),
    ),
  );
}

Future<ui.Image> _decode(WidgetTester tester, Uint8List png) async {
  final ui.Image? image = await tester.runAsync(() async {
    final ui.Codec codec = await ui.instantiateImageCodec(png);
    final ui.FrameInfo frame = await codec.getNextFrame();
    return frame.image;
  });
  return image!;
}

void main() {
  testWidgets('分享长图：1080px 宽，底部带落款', (WidgetTester tester) async {
    await _pumpNote(tester);
    final Size boxSize = tester.getSize(find.byType(SizedBox).first);
    final RenderObject layout =
        tester.renderObject(find.byType(SizedBox).first);

    final Uint8List? bytes = await tester.runAsync(() {
      return renderDocumentShareImage(
        documentLayout: layout,
        background: const Color(0xFFFFFFFF),
        updatedAt: DateTime(2026, 11, 16),
      );
    });

    expect(bytes, isNotNull);
    final Uint8List png = bytes!;
    // PNG 文件头。
    expect(png.sublist(0, 8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);

    final ui.Image image = await _decode(tester, png);
    final double ratio = 1080 / boxSize.width;
    expect(image.width, 1080);
    // 正文 + 24 上留白 + 20 落款间距 + 16 落款行 + 24 下留白。
    expect(image.height, ((boxSize.height + 84) * ratio).round());
    image.dispose();
  });

  testWidgets('深色纸面：落款与正文同图输出', (WidgetTester tester) async {
    await _pumpNote(tester);
    final Size boxSize = tester.getSize(find.byType(SizedBox).first);
    final RenderObject layout =
        tester.renderObject(find.byType(SizedBox).first);

    final Uint8List? bytes = await tester.runAsync(() {
      return renderDocumentShareImage(
        documentLayout: layout,
        background: const Color(0xFF1A1A1A),
        updatedAt: DateTime(2026, 11, 16),
      );
    });

    expect(bytes, isNotNull);
    final ui.Image image = await _decode(tester, bytes!);
    expect(image.width, 1080);
    expect(
      image.height,
      ((boxSize.height + 84) * (1080 / boxSize.width)).round(),
    );
    image.dispose();
  });
}
