import 'dart:math';

import 'package:flutter/services.dart';

/// 安全能力的 Dart 入口：系统凭证、Keystore 加解密、PIN 哈希、截屏保护。
///
/// 全部走已有 `xiaoji/native` 通道，不引入第三方插件。
class SecurityService {
  const SecurityService();

  static const MethodChannel _channel = MethodChannel('xiaoji/native');

  /// 设备是否设置了安全锁屏。
  Future<bool> isDeviceSecure() async {
    final bool? value =
        await _channel.invokeMethod<bool>('isDeviceSecure');
    return value ?? false;
  }

  /// 唤起系统凭证（PIN/图案/密码/指纹），返回是否验证通过。
  Future<bool> authenticate({String reason = '验证身份后继续'}) async {
    final bool? value = await _channel.invokeMethod<bool>(
      'authenticate',
      <String, Object?>{'reason': reason},
    );
    return value ?? false;
  }

  /// 生成 16 字节随机盐（base64）。
  Future<String> randomSalt() async {
    final String? value = await _channel.invokeMethod<String>('randomSalt');
    if (value == null) {
      throw const SecurityException('无法生成安全随机数');
    }
    return value;
  }

  /// PBKDF2 哈希 PIN（salt 为 base64 字节串，返回 base64 哈希）。
  Future<String> hashPin({required String pin, required String salt}) async {
    final String? value = await _channel.invokeMethod<String>(
      'hashPin',
      <String, Object?>{'pin': pin, 'salt': salt},
    );
    if (value == null) {
      throw const SecurityException('PIN 处理失败');
    }
    return value;
  }

  /// AES-256-GCM 加密（密钥在 Android Keystore）。
  Future<String> sealText(String plain) async {
    final String? value = await _channel.invokeMethod<String>(
      'sealText',
      <String, Object?>{'text': plain},
    );
    if (value == null) {
      throw const SecurityException('加密失败');
    }
    return value;
  }

  /// 解密 [sealText] 的结果。
  Future<String> openText(String payload) async {
    final String? value = await _channel.invokeMethod<String>(
      'openText',
      <String, Object?>{'payload': payload},
    );
    if (value == null) {
      throw const SecurityException('解密失败');
    }
    return value;
  }

  /// 开关截屏/多任务预览保护（FLAG_SECURE）。
  ///
  /// 直接作用于窗口标志位。多处都需要禁止截屏（应用锁、锁定笔记编辑页），
  /// 互相独立开关会把对方的保护清掉，常规调用请用 [setSecureHolder]。
  Future<void> setSecureScreen(bool enabled) async {
    await _channel.invokeMethod<void>(
      'setSecureScreen',
      <String, Object?>{'enabled': enabled},
    );
  }

  /// 当前持有「禁止截屏」的调用方集合。
  ///
  /// 应用锁解锁、锁定笔记退出这些动作互不相干：只要还有一处需要保护，
  /// FLAG_SECURE 就必须保持开启。用集合而不是布尔值，才能正确合并。
  static final Set<String> _secureHolders = <String>{};

  /// 登记 / 注销某个调用方的截屏保护需求。
  ///
  /// [key] 唯一标识调用方（如 `applock`、`note:<id>`），同一 key 重复登记
  /// 不会叠加。只有集合状态真的变化时才下发原生调用。
  Future<void> setSecureHolder(String key, bool enabled) async {
    final bool changed =
        enabled ? _secureHolders.add(key) : _secureHolders.remove(key);
    if (!changed) {
      return;
    }
    await setSecureScreen(_secureHolders.isNotEmpty);
  }

  /// 生成一个 6 位数字 PIN（首次设置时的默认建议值）。
  static String generatePin() {
    final random = Random.secure();
    return List<String>.generate(6, (_) => random.nextInt(10).toString()).join();
  }
}

class SecurityException implements Exception {
  const SecurityException(this.message);

  final String message;

  @override
  String toString() => message;
}
