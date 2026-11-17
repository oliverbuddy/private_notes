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

/// 外部文件的落库方式。
enum OpenedFileKind {
  /// 图片：导入后内联进正文（`![](assets/…)`）。
  image,

  /// 其他文件：导入后作为附件卡片（`[文件名](assets/…)`）。
  file,
}

/// 其他 App 「用其他应用打开 / 分享到小记」送进来、需要导入成小记的文件。
///
/// 原生侧已把文件拷到应用缓存目录，[path] 是可直接读的本地绝对路径，
/// 不依赖外部 content:// 的临时授权。
class OpenedFile {
  const OpenedFile({
    required this.name,
    required this.path,
    this.kind = OpenedFileKind.file,
    this.error,
  });

  /// 文件名（含扩展名），写进附件卡片的就是它。
  final String name;

  /// 缓存目录下的本地绝对路径；导入失败时为空串。
  final String path;

  /// 图片走正文内联，其余走附件卡片。
  final OpenedFileKind kind;

  /// 原生侧的失败原因（`too_large` / `copy_failed`）；成功时为 null。
  final String? error;

  bool get isImage => kind == OpenedFileKind.image;
}

/// 读取一次「用其他应用打开」的文件（读后即清空）。
///
/// 冷启动与回到前台各调用一次；没有待导入文件时返回 null。文件过大或
/// 复制失败时也会返回一条带 [OpenedFile.error] 的记录，由调用方提示。
Future<OpenedFile?> consumeOpenedFile() async {
  if (!PlatformFeatures.isAndroid) {
    return null;
  }
  try {
    final Map<Object?, Object?>? map = await _channel
        .invokeMethod<Map<Object?, Object?>>('consumeOpenedFile');
    if (map == null) {
      return null;
    }
    final String name = (map['name'] as String?) ?? '导入的文件';
    final String path = (map['path'] as String?) ?? '';
    final String? error = map['error'] as String?;
    if (error != null) {
      return OpenedFile(name: name, path: '', error: error);
    }
    if (path.isEmpty) {
      return null;
    }
    final String kind = (map['kind'] as String?) ?? '';
    final String mime = (map['mime'] as String?) ?? '';
    return OpenedFile(
      name: name,
      path: path,
      kind: kind == 'image' || mime.startsWith('image/')
          ? OpenedFileKind.image
          : OpenedFileKind.file,
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
