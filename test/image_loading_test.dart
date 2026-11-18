import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/widgets/image_block_view.dart';
import 'package:xiaoji/home/note_tile_compact.dart';
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/theme/app_theme.dart';
import 'package:xiaoji/ui/adaptive_image.dart';

/// 1×1 透明 PNG：验证真实图片走「文件头读尺寸 + 按显示尺寸解码」。
const String _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

Future<void> _pumpFrames(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// 取出 ResizeImage 的解码宽度，并确认没有强制高度（否则会压扁比例）。
int _resizeWidthOf(WidgetTester tester) {
  final Image image = tester.widget<Image>(find.byType(Image).first);
  final ImageProvider provider = image.image;
  expect(provider, isA<ResizeImage>(), reason: '本地图片必须带 cacheWidth 解码');
  final ResizeImage resized = provider as ResizeImage;
  expect(resized.height, isNull, reason: '缩略图只能限制宽度，保持原始宽高比');
  return resized.width!;
}

void main() {
  testWidgets('列表缩略图按显示尺寸解码，不解原图', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final Directory temp = Directory.systemTemp.createTempSync('xiaoji_thumb_');
    addTearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });
    final File file = File('${temp.path}/tiny.png')
      ..writeAsBytesSync(base64Decode(_tinyPngBase64));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: NoteTileCompact(
            note: Note(
              id: 'thumb',
              created: DateTime(2026, 11, 1),
              updated: DateTime(2026, 11, 1),
              body: '带图的一条',
            ),
            thumbnailPaths: <String>[file.path],
            imageCount: 1,
            onTap: () {},
            onLongPress: () {},
          ),
        ),
      ),
    );
    await _pumpFrames(tester);

    // 40dp × dpr 3 = 120，按 8 对齐后仍是 120。
    expect(_resizeWidthOf(tester), 120);
  });

  testWidgets('大图转场复用正文解码宽度，首次打开也有缓存', (
    WidgetTester tester,
  ) async {
    final Directory temp = Directory.systemTemp.createTempSync('xiaoji_flight_');
    addTearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });
    final File file = File('${temp.path}/tiny.png')
      ..writeAsBytesSync(base64Decode(_tinyPngBase64));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    buildImageViewerRoute(
                      sourceRect: const Rect.fromLTWH(20, 20, 120, 120),
                      absolutePath: file.path,
                      flightCacheWidth: 800,
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    // 第一帧推路由，第二帧才开始跑转场、构建飞行图层。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final ResizeImage flight = tester
        .widgetList<Image>(find.byType(Image))
        .map((Image image) => image.image)
        .whereType<ResizeImage>()
        .first;
    expect(flight.width, 800);
    expect(flight.height, isNull);

    // 走完转场并清空路由，避免残留动画影响测试收尾。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('详情图片框：用文件头拿真实比例（不再整图解码）', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final Directory temp = Directory.systemTemp.createTempSync('xiaoji_frame_');
    addTearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });
    final File file = File('${temp.path}/tiny.png')
      ..writeAsBytesSync(base64Decode(_tinyPngBase64));

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SizedBox(
            width: 800,
            child: AdaptiveImageFrame(
              path: file.path,
              child: Image.file(
                File(file.path),
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
      ),
    );
    // 文件头解析是真实异步 I/O：让出一次真实时间再泵帧。
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pump();

    final Rect clip = tester.getRect(find.byType(ClipRRect));
    expect(
      clip.width,
      closeTo(clip.height, 0.5),
      reason: '1×1 图片应按真实比例得到正方形盒子',
    );
    expect(tester.takeException(), isNull);
  });
}
