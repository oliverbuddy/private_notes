import 'package:flutter/services.dart';

import '../platform/platform_features.dart';

const MethodChannel _channel = MethodChannel('xiaoji/native');

/// 其他 App 分享进来的内容。
class SharedContent {
  const SharedContent({this.text, this.imagePath});

  /// 分享的纯文本（可能为空）。
  final String? text;

  /// 已拷贝到应用缓存目录的图片路径（可能为空）。
  final String? imagePath;

  bool get isEmpty => (text ?? '').isEmpty && imagePath == null;
}

/// 读取一次「分享到小记」的内容（读后即清空）。
///
/// 冷启动与回到前台时各调用一次：系统只会把内容放在启动 Intent 里，
/// 应用运行中再分享会走 onNewIntent 暂存，回到前台时消费。
Future<SharedContent?> consumeSharedContent() async {
  if (!PlatformFeatures.canReceiveShare) {
    return null;
  }
  try {
    final Map<Object?, Object?>? map = await _channel
        .invokeMethod<Map<Object?, Object?>>('consumeSharedContent');
    if (map == null) {
      return null;
    }
    final content = SharedContent(
      text: map['text'] as String?,
      imagePath: map['path'] as String?,
    );
    return content.isEmpty ? null : content;
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
