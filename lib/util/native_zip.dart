import 'dart:async';

import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('xiaoji/native');

/// 用原生 `ZipOutputStream` 把 Xiaoji 目录打成 zip。
///
/// 走流式读写，Dart 侧只传路径，不把整个备份读成 `Uint8List` ——
/// 笔记/图片多的用户导出时不会 OOM。
/// [excludes] 是相对 [sourceRoot] 的路径（目录名等价于排除整个子目录），
/// 用于默认排除锁定笔记（`notes/<年月>/<id>.md` + `assets/<id>/`）。
///
/// [overrides] 把某个条目的相对路径映射到另一个本地文件，用于「明文导出」：
/// 磁盘上是密文信封，zip 里要写解密后的明文。
Future<void> zipNotesToFile({
  required String sourceRoot,
  required String targetPath,
  List<String> excludes = const <String>[],
  Map<String, String> overrides = const <String, String>{},
}) async {
  await _channel.invokeMethod<void>('zipTree', <String, Object?>{
    'sourceRoot': sourceRoot,
    'targetPath': targetPath,
    'excludes': excludes,
    'overrides': overrides,
  });
}

/// 用原生 `ZipInputStream` 解压到指定目录（含 `..` 路径防护）。
Future<void> unzipTo({
  required String zipPath,
  required String destDir,
}) async {
  await _channel.invokeMethod<void>('unzipTo', <String, Object?>{
    'zipPath': zipPath,
    'destDir': destDir,
  });
}

/// 拉起系统「另存为」（SAF），把 zip 流式复制到用户选的位置。
///
/// 返回保存后的 content uri；用户取消返回 null。
Future<String?> saveFileToUser({
  required String sourcePath,
  required String fileName,
}) async {
  return _channel.invokeMethod<String>('saveFileToUser', <String, Object?>{
    'sourcePath': sourcePath,
    'fileName': fileName,
  });
}
