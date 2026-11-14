import 'dart:io';

import 'package:flutter/services.dart';

/// 备份包口令加密的 Dart 入口。
///
/// 加解密都在原生层完成（流式，不占 Dart 内存）：格式为
/// `XJENC1` + 16 字节盐 + 12 字节 IV + AES-256-GCM 密文，
/// 密钥由 PBKDF2-HMAC-SHA1 派生。口令永远不落盘到明文位置，
/// 外置备份需要的口令由 Keystore 封存（见 [SecurityService.sealText]）。
const MethodChannel _channel = MethodChannel('xiaoji/native');

/// 加密包的文件头。与原生 `BackupBridge.ENC_MAGIC` 保持一致。
const String backupEncryptedMagic = 'XJENC1';

/// 加密备份的扩展名。故意不用 `.zip`：恢复入口按内容判断，
/// 但系统文件管理器不该把它当压缩包直接打开。
const String encryptedBackupExtension = '.xiaoji';

/// 口令错误（或文件损坏导致认证失败）。
class BackupPasswordException implements Exception {
  const BackupPasswordException([this.message = '口令不正确或文件已损坏']);

  final String message;

  @override
  String toString() => message;
}

/// 文件是否是口令加密的备份（只读前 6 字节，不加载整个文件）。
Future<bool> isEncryptedBackup(String path) async {
  RandomAccessFile? raf;
  try {
    raf = await File(path).open();
    if (await raf.length() < backupEncryptedMagic.length) {
      return false;
    }
    final bytes = await raf.read(backupEncryptedMagic.length);
    return String.fromCharCodes(bytes) == backupEncryptedMagic;
  } catch (_) {
    // 读不到文件头就按「不是加密包」处理，让后续流程给出明确错误。
    return false;
  } finally {
    try {
      await raf?.close();
    } catch (_) {
      // 关闭失败不影响判断结果。
    }
  }
}

/// 把 [sourcePath] 加密写到 [targetPath]。
Future<void> encryptBackupFile({
  required String sourcePath,
  required String targetPath,
  required String password,
}) async {
  await _channel.invokeMethod<String>('encryptFile', <String, Object?>{
    'sourcePath': sourcePath,
    'targetPath': targetPath,
    'password': password,
  });
}

/// 把 [sourcePath] 解密写到 [targetPath]；口令错误抛 [BackupPasswordException]。
Future<void> decryptBackupFile({
  required String sourcePath,
  required String targetPath,
  required String password,
}) async {
  try {
    await _channel.invokeMethod<String>('decryptFile', <String, Object?>{
      'sourcePath': sourcePath,
      'targetPath': targetPath,
      'password': password,
    });
  } on PlatformException catch (error) {
    if (error.code == 'bad_password' || error.code == 'not_encrypted') {
      throw BackupPasswordException(error.message ?? '口令不正确或文件已损坏');
    }
    rethrow;
  }
}
