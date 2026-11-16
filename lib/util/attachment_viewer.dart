import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../platform/platform_features.dart';

const MethodChannel _channel = MethodChannel('xiaoji/native');

/// 用系统 / 第三方查看器打开附件（PDF、Office、文本、压缩包等）。
///
/// 返回 true 表示已经交给外部应用打开；false 表示当前平台没有这条能力
/// （测试、桌面），由调用方决定要不要提示。
///
/// 为什么先拷到缓存目录：附件存在应用私有目录 `assets/` 下，`FileProvider`
/// 只注册了缓存目录（`share_paths.xml`，与分享长图同一条链路）。复制一份
/// 再换成 `content://` 授权 URI，既不用放宽 provider 的暴露范围，也不用
/// 申请任何存储权限。
///
/// 失败时抛 [PlatformException]（如 `no_viewer` = 设备上没有能打开该格式的
/// 应用），调用方负责提示。
Future<bool> openAttachmentWithSystemViewer(String sourcePath) async {
  if (!PlatformFeatures.isAndroid) {
    return false;
  }
  final File source = File(sourcePath);
  if (!await source.exists()) {
    throw PlatformException(code: 'missing_file', message: '文件不存在');
  }
  final Directory directory = Directory(
    p.join((await getTemporaryDirectory()).path, 'open'),
  );
  await directory.create(recursive: true);
  final File target = File(p.join(directory.path, p.basename(sourcePath)));
  await source.copy(target.path);
  await _channel.invokeMethod<void>('openFile', <String, Object?>{
    'path': target.path,
  });
  return true;
}
