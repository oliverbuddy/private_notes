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

/// 让用户选一个文件夹作为「外置备份」位置（SAF 目录授权）。
///
/// 返回树 URI（授权已持久化，重启后仍可写入）；用户取消返回 null。
Future<String?> pickBackupDirectory() async {
  return _channel.invokeMethod<String>('pickDirectory');
}

/// 把本地文件写进已授权的目录，并按前缀保留最近 [keep] 份备份。
///
/// 返回写入后的 content uri。目录授权失效（用户删了文件夹/撤销权限）时
/// 原生侧抛错，由上层提示「重新选择文件夹」。
Future<String> writeFileToTree({
  required String treeUri,
  required String sourcePath,
  required String fileName,
  String keepPrefix = 'xiaoji-',
  int keep = 3,
}) async {
  final String? uri =
      await _channel.invokeMethod<String>('writeToTree', <String, Object?>{
    'treeUri': treeUri,
    'sourcePath': sourcePath,
    'fileName': fileName,
    'keepPrefix': keepPrefix,
    'keep': keep,
  });
  if (uri == null || uri.isEmpty) {
    throw StateError('外置目录写入失败');
  }
  return uri;
}
