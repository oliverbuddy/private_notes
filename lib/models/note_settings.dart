import 'package:flutter/material.dart';

/// 主题偏好。落盘时用 [wireValue]，不用枚举下标 —— 下标一改就全乱。
enum AppThemeMode {
  system('system', '跟随系统'),
  light('light', '浅色'),
  dark('dark', '深色');

  const AppThemeMode(this.wireValue, this.label);

  final String wireValue;
  final String label;

  ThemeMode get themeMode {
    switch (this) {
      case AppThemeMode.system:
        return ThemeMode.system;
      case AppThemeMode.light:
        return ThemeMode.light;
      case AppThemeMode.dark:
        return ThemeMode.dark;
    }
  }

  static AppThemeMode fromWire(String? raw) {
    for (final mode in AppThemeMode.values) {
      if (mode.wireValue == raw) {
        return mode;
      }
    }
    return AppThemeMode.system;
  }
}

/// 列表密度。
enum ListDensity {
  comfortable('comfortable', '舒适'),
  compact('compact', '紧凑');

  const ListDensity(this.wireValue, this.label);

  final String wireValue;
  final String label;

  static ListDensity fromWire(String? raw) {
    for (final density in ListDensity.values) {
      if (density.wireValue == raw) {
        return density;
      }
    }
    return ListDensity.comfortable;
  }
}

/// `settings.json` 的内存模型。
///
/// 用不可变对象 + `copyWith`：根 widget 靠对象身份判断「设置真的变了吗」，
/// 没变就不重建 ThemeData，避免打字时整棵树重排。
@immutable
class NoteSettings {
  const NoteSettings({
    this.theme = AppThemeMode.system,
    this.density = ListDensity.comfortable,
  });

  final AppThemeMode theme;
  final ListDensity density;

  ThemeMode get themeMode => theme.themeMode;

  NoteSettings copyWith({AppThemeMode? theme, ListDensity? density}) {
    return NoteSettings(
      theme: theme ?? this.theme,
      density: density ?? this.density,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'theme': theme.wireValue,
        'density': density.wireValue,
      };

  /// 容错解析：字段缺失或类型不对都回落到默认值，配置文件坏掉不能让 app 起不来。
  ///
  /// 不能写成 `json['theme'] as String?`：字段被手改成数字时那是一次运行时
  /// `TypeError`，会把整条 `settings.json` 连带 app 一起打挂。先 `is` 判类型，
  /// 才配得上「类型不对也回落默认值」这句承诺。
  static NoteSettings fromJson(Map<String, dynamic> json) {
    final theme = json['theme'];
    final density = json['density'];
    return NoteSettings(
      theme: AppThemeMode.fromWire(theme is String ? theme : null),
      density: ListDensity.fromWire(density is String ? density : null),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is NoteSettings && other.theme == theme && other.density == density;

  @override
  int get hashCode => Object.hash(theme, density);
}
