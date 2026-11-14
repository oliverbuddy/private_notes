import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../platform/platform_features.dart';

const MethodChannel _channel = MethodChannel('xiaoji/native');

/// 只有桌面端才允许走 Dart 回退。
///
/// Android/iOS 上缺少原生实现是真错误（比如打包进错 APK），必须让上层
/// 看到 MissingPluginException，不能悄悄换成另一套实现掩盖问题。
void _ensureDesktopFallback() {
  if (!PlatformFeatures.isDesktop) {
    throw MissingPluginException(
      '当前平台没有原生实现',
    );
  }
}

/// 用原生 `ZipOutputStream` 把 Xiaoji 目录打成 zip。
///
/// 走流式读写，Dart 侧只传路径，不把整个备份读成 `Uint8List` ——
/// 笔记/图片多的用户导出时不会 OOM。
/// [excludes] 是相对 [sourceRoot] 的路径（目录名等价于排除整个子目录），
/// 用于默认排除锁定笔记（`notes/<年月>/<id>.md` + `assets/<id>/`）。
///
/// [overrides] 把某个条目的相对路径映射到另一个本地文件，用于「明文导出」：
/// 磁盘上是密文信封，zip 里要写解密后的明文。
///
/// 桌面端没有原生实现时退回 Dart 版（[ZipFileEncoder] 同样逐文件流式写入，
/// 不会把整个目录读进内存）。
Future<void> zipNotesToFile({
  required String sourceRoot,
  required String targetPath,
  List<String> excludes = const <String>[],
  Map<String, String> overrides = const <String, String>{},
}) async {
  try {
    await _channel.invokeMethod<void>('zipTree', <String, Object?>{
      'sourceRoot': sourceRoot,
      'targetPath': targetPath,
      'excludes': excludes,
      'overrides': overrides,
    });
  } on MissingPluginException {
    _ensureDesktopFallback();
    await _zipTreeInDart(
      sourceRoot: sourceRoot,
      targetPath: targetPath,
      excludes: excludes,
      overrides: overrides,
    );
  }
}

/// 用原生 `ZipInputStream` 解压到指定目录（含 `..` 路径防护）。
Future<void> unzipTo({
  required String zipPath,
  required String destDir,
}) async {
  try {
    await _channel.invokeMethod<void>('unzipTo', <String, Object?>{
      'zipPath': zipPath,
      'destDir': destDir,
    });
  } on MissingPluginException {
    _ensureDesktopFallback();
    await _unzipInDart(zipPath: zipPath, destDir: destDir);
  }
}

/// 拉起系统「另存为」（SAF），把 zip 流式复制到用户选的位置。
///
/// 返回保存后的路径；用户取消返回 null。
/// 加密包（`.xiaoji`）传 [mimeType] 为 `application/octet-stream`。
Future<String?> saveFileToUser({
  required String sourcePath,
  required String fileName,
  String? mimeType,
}) async {
  try {
    return await _channel
        .invokeMethod<String>('saveFileToUser', <String, Object?>{
      'sourcePath': sourcePath,
      'fileName': fileName,
      if (mimeType != null) 'mimeType': mimeType,
    });
  } on MissingPluginException {
    _ensureDesktopFallback();
    // 桌面：系统保存面板由 file_picker 提供，落盘由 Dart 完成。
    final String? target = await FilePicker.platform.saveFile(
      dialogTitle: '保存文件',
      fileName: fileName,
    );
    if (target == null || target.isEmpty) {
      return null;
    }
    await File(sourcePath).copy(target);
    return target;
  }
}

/// 读取备份包的摘要（manifest + 条目计数），不解压内容。
///
/// 返回 null 表示当前平台没有原生通道（测试/桌面），调用方自行回退。
Future<Map<Object?, Object?>?> inspectBackupZip(String zipPath) async {
  try {
    return await _channel.invokeMethod<Map<Object?, Object?>>(
      'inspectZip',
      <String, Object?>{'zipPath': zipPath},
    );
  } on MissingPluginException {
    _ensureDesktopFallback();
    return null;
  }
}

/// 让用户选一个文件夹作为「外置备份」位置。
///
/// Android 返回 SAF 树 URI（授权已持久化）；桌面返回普通目录路径。
/// 用户取消返回 null。
Future<String?> pickBackupDirectory() async {
  try {
    return await _channel.invokeMethod<String>('pickDirectory');
  } on MissingPluginException {
    _ensureDesktopFallback();
    return FilePicker.platform.getDirectoryPath(dialogTitle: '选择备份文件夹');
  }
}

/// 把本地文件写进已授权的目录，并按前缀保留最近 [keep] 份备份。
///
/// 返回写入后的路径。目录不可写（用户删了文件夹/撤销权限）时抛错，
/// 由上层提示「重新选择文件夹」。
Future<String> writeFileToTree({
  required String treeUri,
  required String sourcePath,
  required String fileName,
  String keepPrefix = 'xiaoji-',
  int keep = 3,
}) async {
  try {
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
  } on MissingPluginException {
    _ensureDesktopFallback();
    return _writeToDirectoryInDart(
      dirPath: treeUri,
      sourcePath: sourcePath,
      fileName: fileName,
      keepPrefix: keepPrefix,
      keep: keep,
    );
  }
}

// ---------------------------------------------------------------------------
// 桌面回退实现
// ---------------------------------------------------------------------------

/// 与原生 `zipTree` 语义一致：跳过 `tmp/` 目录与 `.tmp` 文件，
/// 命中 [excludes]（自身或子路径）的条目整体排除；
/// [overrides] 既可以是「替换已有条目」，也可以是「额外写入」。
Future<void> _zipTreeInDart({
  required String sourceRoot,
  required String targetPath,
  required List<String> excludes,
  required Map<String, String> overrides,
}) async {
  final Directory source = Directory(sourceRoot);
  if (!await source.exists()) {
    throw StateError('笔记目录不存在');
  }
  final File target = File(targetPath);
  await target.parent.create(recursive: true);
  final Set<String> emitted = <String>{};
  final ZipFileEncoder encoder = ZipFileEncoder();
  try {
    encoder.create(target.path);
    await for (final FileSystemEntity entity
        in source.list(recursive: true, followLinks: false)) {
      if (entity is! File || entity.path.endsWith('.tmp')) {
        continue;
      }
      final String relative =
          p.relative(entity.path, from: source.path).replaceAll('\\', '/');
      if (relative.startsWith('tmp/') || relative.contains('/tmp/')) {
        continue;
      }
      if (_isExcluded(relative, excludes)) {
        continue;
      }
      final String? override = overrides[relative];
      final File payload = override == null ? entity : File(override);
      if (!await payload.exists()) {
        continue;
      }
      await encoder.addFile(payload, relative);
      emitted.add(relative);
    }
    // overrides 里源目录不存在的条目（manifest.json 就是这种）额外补写。
    for (final MapEntry<String, String> entry in overrides.entries) {
      if (emitted.contains(entry.key) || _isExcluded(entry.key, excludes)) {
        continue;
      }
      final File payload = File(entry.value);
      if (!await payload.exists()) {
        continue;
      }
      await encoder.addFile(payload, entry.key);
      emitted.add(entry.key);
    }
    await encoder.close();
  } catch (error) {
    // 失败不能留下半截 zip：下次列表里会被当成可用备份。
    try {
      if (await target.exists()) {
        await target.delete();
      }
    } catch (_) {
      // 删不掉也不影响把原始错误抛给上层。
    }
    rethrow;
  }
}

Future<void> _unzipInDart({
  required String zipPath,
  required String destDir,
}) async {
  final File zip = File(zipPath);
  if (!await zip.exists()) {
    throw StateError('备份文件不存在');
  }
  final Archive archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
  final Directory dest = Directory(destDir);
  await dest.create(recursive: true);
  for (final ArchiveFile entry in archive.files) {
    final String name = entry.name.replaceAll('\\', '/');
    // 恶意压缩包防护：跳过 ../ 越目录条目，其余照常解。
    if (name.contains('..')) {
      continue;
    }
    final File target = File(p.join(dest.path, name));
    if (entry.isFile) {
      await target.parent.create(recursive: true);
      await target.writeAsBytes(entry.content as List<int>, flush: true);
    } else {
      await target.create(recursive: true);
    }
  }
}

Future<String> _writeToDirectoryInDart({
  required String dirPath,
  required String sourcePath,
  required String fileName,
  required String keepPrefix,
  required int keep,
}) async {
  final Directory dir = Directory(dirPath);
  await dir.create(recursive: true);
  final File target = File(p.join(dir.path, fileName));
  await File(sourcePath).copy(target.path);
  if (keep > 0) {
    try {
      final List<File> candidates = <File>[];
      await for (final FileSystemEntity entity in dir.list()) {
        if (entity is! File) {
          continue;
        }
        final String name = p.basename(entity.path);
        if (name.startsWith(keepPrefix) &&
            (name.endsWith('.zip') || name.endsWith('.xiaoji'))) {
          candidates.add(entity);
        }
      }
      final List<(File, DateTime)> dated = <(File, DateTime)>[
        for (final File file in candidates)
          (file, (await file.stat()).modified),
      ];
      dated.sort(((File, DateTime) a, (File, DateTime) b) =>
          b.$2.compareTo(a.$2));
      for (int i = keep; i < dated.length; i++) {
        final File file = dated[i].$1;
        if (file.path == target.path) {
          continue;
        }
        try {
          await file.delete();
        } catch (_) {
          // 某个文件删不掉（只读/被占用）不影响备份结果。
        }
      }
    } catch (_) {
      // 清理旧备份是尽力而为，失败不回滚刚写入的备份。
    }
  }
  return target.path;
}

bool _isExcluded(String relative, List<String> excludes) {
  return excludes.any((String item) {
    if (item.isEmpty) {
      return false;
    }
    return relative == item || relative.startsWith('$item/');
  });
}
