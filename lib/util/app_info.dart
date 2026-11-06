import 'package:flutter/services.dart';

/// 应用版本信息。
///
/// 从原生 `PackageManager` 读取，而不是在 Dart 里写死常量 ——
/// 版本号只维护 `pubspec.yaml` 一处，设置页展示的永远是实际安装包的信息。
class AppInfo {
  const AppInfo({
    required this.versionName,
    required this.versionCode,
    required this.packageName,
  });

  final String versionName;
  final int versionCode;
  final String packageName;

  /// `1.4.8 (15)`
  String get displayVersion =>
      versionCode > 0 ? '$versionName ($versionCode)' : versionName;
}

/// 读取失败（非 Android、通道不可用）时返回 null，由界面显示占位符。
Future<AppInfo?> loadAppInfo() async {
  try {
    final Map<Object?, Object?>? map =
        await const MethodChannel('xiaoji/native')
            .invokeMethod<Map<Object?, Object?>>('appInfo');
    if (map == null) {
      return null;
    }
    return AppInfo(
      versionName: (map['versionName'] as String?) ?? '',
      versionCode: (map['versionCode'] as num?)?.toInt() ?? 0,
      packageName: (map['packageName'] as String?) ?? '',
    );
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
