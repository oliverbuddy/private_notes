import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/util/share.dart';

/// 「用其他应用打开」/「分享到小记」的原生通道解析。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('xiaoji/native');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void mockChannel(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  void runAsAndroid() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  }

  test('打开 .md：读出文件名与正文', () async {
    runAsAndroid();
    mockChannel((MethodCall call) async {
      if (call.method != 'consumeOpenedMarkdown') {
        return null;
      }
      return <Object?, Object?>{
        'name': '周报.md',
        'text': '# 周报\n\n本周完成外部打开导入流程',
      };
    });

    final OpenedMarkdown? opened = await consumeOpenedMarkdown();

    expect(opened, isNotNull);
    expect(opened!.name, '周报.md');
    expect(opened.text, contains('本周完成外部打开导入流程'));
  });

  test('打开 .md：空白正文不建笔记', () async {
    runAsAndroid();
    mockChannel((MethodCall call) async {
      if (call.method != 'consumeOpenedMarkdown') {
        return null;
      }
      return <Object?, Object?>{'name': '空.md', 'text': '   \n'};
    });

    expect(await consumeOpenedMarkdown(), isNull);
  });

  test('打开 .md：CRLF 统一成 \\n', () async {
    runAsAndroid();
    mockChannel((MethodCall call) async {
      if (call.method != 'consumeOpenedMarkdown') {
        return null;
      }
      return <Object?, Object?>{
        'name': 'win.md',
        'text': '# 标题\r\n\r\n第一行\r\n第二行',
      };
    });

    final OpenedMarkdown? opened = await consumeOpenedMarkdown();

    expect(opened, isNotNull);
    expect(opened!.text, '# 标题\n\n第一行\n第二行');
  });

  test('非 Android 平台不读原生通道', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    var called = false;
    mockChannel((MethodCall call) async {
      called = true;
      return <Object?, Object?>{'name': 'a.md', 'text': '# a'};
    });

    expect(await consumeOpenedMarkdown(), isNull);
    expect(called, isFalse);
  });

  test('打开 PDF：解析出缓存路径与文件名', () async {
    runAsAndroid();
    mockChannel((MethodCall call) async {
      if (call.method != 'consumeOpenedFile') {
        return null;
      }
      return <Object?, Object?>{
        'name': '报告.pdf',
        'path': '/data/user/0/com.xiaoji.xiaoji/cache/open-1-报告.pdf',
      };
    });

    final OpenedFile? opened = await consumeOpenedFile();

    expect(opened, isNotNull);
    expect(opened!.name, '报告.pdf');
    expect(opened.path, contains('cache/open-'));
  });

  test('打开 PDF：path 为空时不打开预览', () async {
    runAsAndroid();
    mockChannel((MethodCall call) async {
      if (call.method != 'consumeOpenedFile') {
        return null;
      }
      return <Object?, Object?>{'name': '报告.pdf', 'path': ''};
    });

    expect(await consumeOpenedFile(), isNull);
  });

  test('打开图片：标记为内联图片', () async {
    runAsAndroid();
    mockChannel((MethodCall call) async {
      if (call.method != 'consumeOpenedFile') {
        return null;
      }
      return <Object?, Object?>{
        'name': '照片.jpg',
        'path': '/cache/open-2-照片.jpg',
        'mime': 'image/jpeg',
        'kind': 'image',
      };
    });

    final OpenedFile? opened = await consumeOpenedFile();

    expect(opened, isNotNull);
    expect(opened!.isImage, isTrue);
    expect(opened.path, contains('cache/open-'));
  });

  test('打开文件：其他类型按附件处理', () async {
    runAsAndroid();
    mockChannel((MethodCall call) async {
      if (call.method != 'consumeOpenedFile') {
        return null;
      }
      return <Object?, Object?>{
        'name': '素材.zip',
        'path': '/cache/open-3-素材.zip',
        'mime': 'application/zip',
        'kind': 'file',
      };
    });

    final OpenedFile? opened = await consumeOpenedFile();

    expect(opened, isNotNull);
    expect(opened!.isImage, isFalse);
    expect(opened.name, '素材.zip');
  });

  test('打开文件：体积超限的原因透传给界面', () async {
    runAsAndroid();
    mockChannel((MethodCall call) async {
      if (call.method != 'consumeOpenedFile') {
        return null;
      }
      return <Object?, Object?>{'name': '大视频.mp4', 'error': 'too_large'};
    });

    final OpenedFile? opened = await consumeOpenedFile();

    expect(opened, isNotNull);
    expect(opened!.error, 'too_large');
    expect(opened.path, isEmpty);
  });

  test('分享文本：仍按原有通道解析', () async {
    runAsAndroid();
    mockChannel((MethodCall call) async {
      if (call.method != 'consumeSharedContent') {
        return null;
      }
      return <Object?, Object?>{
        'type': 'text',
        'text': '来自其他 App 的一段话',
      };
    });

    final SharedContent? content = await consumeSharedContent();

    expect(content, isNotNull);
    expect(content!.text, '来自其他 App 的一段话');
  });
}
