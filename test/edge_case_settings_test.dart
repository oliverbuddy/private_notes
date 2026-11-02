import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/models/note_settings.dart';

void main() {
  group('边界：NoteSettings 容错解析', () {
    test('空 map 回落默认值', () {
      final settings = NoteSettings.fromJson(<String, dynamic>{});
      expect(settings.theme, AppThemeMode.system);
      expect(settings.density, ListDensity.comfortable);
    });

    test('字段为 null 时回落默认值', () {
      final settings = NoteSettings.fromJson(<String, dynamic>{
        'theme': null,
        'density': null,
      });
      expect(settings, const NoteSettings());
    });

    test('未知枚举值回落默认值', () {
      final settings = NoteSettings.fromJson(<String, dynamic>{
        'theme': 'purple',
        'density': 'huge',
      });
      expect(settings.theme, AppThemeMode.system);
      expect(settings.density, ListDensity.comfortable);
    });

    test('未知主题但不影响密度', () {
      final settings = NoteSettings.fromJson(<String, dynamic>{
        'theme': 'purple',
        'density': 'compact',
      });
      expect(settings.theme, AppThemeMode.system);
      expect(settings.density, ListDensity.compact);
    });

    test('toJson 与 fromJson 互逆', () {
      const original = NoteSettings(
        theme: AppThemeMode.dark,
        density: ListDensity.compact,
      );
      expect(NoteSettings.fromJson(original.toJson()), original);
    });

    test('wireValue 与枚举下标解耦（已知值固定）', () {
      expect(AppThemeMode.system.wireValue, 'system');
      expect(AppThemeMode.light.wireValue, 'light');
      expect(AppThemeMode.dark.wireValue, 'dark');
      expect(ListDensity.comfortable.wireValue, 'comfortable');
      expect(ListDensity.compact.wireValue, 'compact');
    });

    test('themeMode 映射正确', () {
      expect(AppThemeMode.system.themeMode, ThemeMode.system);
      expect(AppThemeMode.light.themeMode, ThemeMode.light);
      expect(AppThemeMode.dark.themeMode, ThemeMode.dark);
    });

    test('相等性与 hashCode 一致', () {
      const a = NoteSettings(theme: AppThemeMode.dark);
      const b = NoteSettings(theme: AppThemeMode.dark);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == a.copyWith(density: ListDensity.compact), isFalse);
    });

    test('copyWith 不改变未传入的字段', () {
      const base = NoteSettings(
        theme: AppThemeMode.light,
        density: ListDensity.compact,
      );
      final next = base.copyWith(theme: AppThemeMode.dark);
      expect(next.theme, AppThemeMode.dark);
      expect(next.density, ListDensity.compact);
    });
  });

  // 回归：旧实现用 `json['theme'] as String?` 强转，字段被手改成数字/布尔时
  // 会抛 TypeError。改法是先 `is String` 判类型，这三个用例盯住这条。
  group('回归：字段类型非法时回落默认且不抛异常', () {
    test('theme 为数字 / 布尔 / null 时都回落 system', () {
      for (final Object? value in <Object?>[1, true, null]) {
        expect(
          () => NoteSettings.fromJson(<String, dynamic>{'theme': value}),
          returnsNormally,
          reason: 'theme=$value 不应抛异常',
        );
        expect(
          NoteSettings.fromJson(<String, dynamic>{'theme': value}).theme,
          AppThemeMode.system,
          reason: 'theme=$value 应回落默认',
        );
      }
    });

    test('density 为数字 / 布尔 / null 时都回落 comfortable', () {
      for (final Object? value in <Object?>[1, true, null]) {
        expect(
          () => NoteSettings.fromJson(<String, dynamic>{'density': value}),
          returnsNormally,
          reason: 'density=$value 不应抛异常',
        );
        expect(
          NoteSettings.fromJson(<String, dynamic>{'density': value}).density,
          ListDensity.comfortable,
          reason: 'density=$value 应回落默认',
        );
      }
    });

    test('两个字段同时类型非法时都回落默认', () {
      final settings = NoteSettings.fromJson(<String, dynamic>{
        'theme': 1,
        'density': true,
      });
      expect(settings, const NoteSettings());
    });

    test('类型非法只影响自己那个字段，合法字段照常生效', () {
      final settings = NoteSettings.fromJson(<String, dynamic>{
        'theme': 1,
        'density': 'compact',
      });
      expect(settings.theme, AppThemeMode.system);
      expect(settings.density, ListDensity.compact);
    });

    test('值为 List 时也不抛异常', () {
      expect(
        () => NoteSettings.fromJson(<String, dynamic>{
          'theme': <String>['dark'],
          'density': <String>['compact'],
        }),
        returnsNormally,
      );
      expect(
        NoteSettings.fromJson(<String, dynamic>{
          'theme': <String>['dark'],
        }).theme,
        AppThemeMode.system,
      );
    });
  });

  group('边界：settings.json 落盘容错', () {
    late Directory tempDir;
    late NoteStore store;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('xiaoji_settings_');
      store = await NoteStore.openAt(tempDir);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('文件不存在时返回默认设置', () async {
      expect(await store.loadSettings(), const NoteSettings());
    });

    test('内容不是合法 json 时返回默认设置', () async {
      await store.settingsFile.writeAsString('{oops');
      expect(await store.loadSettings(), const NoteSettings());
    });

    test('json 顶层不是对象时返回默认设置', () async {
      await store.settingsFile.writeAsString('"just a string"');
      expect(await store.loadSettings(), const NoteSettings());
    });

    test('字段类型不是字符串时返回默认设置（不抛异常）', () async {
      await store.settingsFile.writeAsString('{"theme": 1, "density": 2}');
      expect(await store.loadSettings(), const NoteSettings());
    });

    test('正常写入后能读回', () async {
      const settings = NoteSettings(
        theme: AppThemeMode.dark,
        density: ListDensity.compact,
      );
      await store.saveSettings(settings);
      expect(await store.loadSettings(), settings);
    });
  });
}
