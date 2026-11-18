import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/ui/local_image.dart';

/// 1×1 透明 PNG：只验证「读文件头拿尺寸」这条路径，不关心像素内容。
const String _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('读取本地图片：只解析文件头得到原始像素尺寸', () async {
    final Directory temp = Directory.systemTemp.createTempSync('xiaoji_img_');
    addTearDown(() {
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });
    final File file = File('${temp.path}/tiny.png')
      ..writeAsBytesSync(base64Decode(_tinyPngBase64));

    final Size? size = await readLocalImagePixelSize(file.path);

    expect(size, isNotNull);
    expect(size!.width, 1);
    expect(size.height, 1);
    // 第二次必须命中缓存，结果一致。
    expect(await readLocalImagePixelSize(file.path), size);
  });

  test('读取本地图片：文件缺失时返回 null，不抛异常', () async {
    expect(await readLocalImagePixelSize('/definitely/missing.png'), isNull);
  });

  testWidgets('解码尺寸按显示尺寸 × dpr 计算并按 8 像素对齐', (tester) async {
    tester.view.devicePixelRatio = 2.5;
    addTearDown(tester.view.reset);

    late int extent;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            extent = localImageDecodeExtent(context, 40, max: 1024);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    // 40 × 2.5 = 100，向上对齐到 8 的倍数 → 104。
    expect(extent, 104);
  });

  testWidgets('解码尺寸不会超过上限', (tester) async {
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    late int extent;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            extent = localImageDecodeExtent(context, 4000, max: 1440);
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(extent, 1440);
  });
}
