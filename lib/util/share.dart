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

/// 其他 App 「用其他应用打开」送进来的 Markdown 文件。
class OpenedMarkdown {
  const OpenedMarkdown({required this.name, required this.text});

  /// 文件名（含扩展名），用于导入提示。
  final String name;

  /// 文件正文（已去掉 UTF-8 BOM）。
  final String text;
}

/// 读取一次「用其他应用打开」的内容（读后即清空）。
///
/// 微信 / 文件管理器点 `.md` 时，原生侧把文件读成文本暂存；冷启动与回到
/// 前台各调用一次，取到后由首页直接建成一条新笔记。
Future<OpenedMarkdown?> consumeOpenedMarkdown() async {
  if (!PlatformFeatures.isAndroid) {
    return null;
  }
  try {
    final Map<Object?, Object?>? map = await _channel
        .invokeMethod<Map<Object?, Object?>>('consumeOpenedMarkdown');
    if (map == null) {
      return null;
    }
    final String text = (map['text'] as String?) ?? '';
    if (text.trim().isEmpty) {
      return null;
    }
    return OpenedMarkdown(
      name: (map['name'] as String?) ?? '导入的笔记.md',
      // 外部 .md 常来自 Windows（CRLF）：统一成 \n，否则每行会多一个
      // 看不见的回车，编辑器里表现为行距忽大忽小。
      text: text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
    );
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
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
