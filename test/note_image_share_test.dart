import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/note_image_share.dart';

void main() {
  testWidgets('分享长图：按详情渲染结果输出 1080px 宽的 PNG', (WidgetTester tester) async {
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

    final RenderObject layout =
        tester.renderObject(find.byType(SizedBox).first);

    final Uint8List? bytes = await tester.runAsync(() {
      return renderDocumentShareImage(
        documentLayout: layout,
        background: const Color(0xFFFFFFFF),
      );
    });

    expect(bytes, isNotNull);
    final Uint8List png = bytes!;
    // PNG 文件头。
    expect(png.sublist(0, 8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);

    final ui.Image? image = await tester.runAsync(() async {
      final ui.Codec codec = await ui.instantiateImageCodec(png);
      final ui.FrameInfo frame = await codec.getNextFrame();
      return frame.image;
    });
    expect(image, isNotNull);
    // 405 逻辑宽 → 1080px。
    expect(image!.width, 1080);
    expect(image.height, greaterThan(40));
    image.dispose();
  });
}
