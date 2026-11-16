import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/home/home_page.dart';
import 'package:xiaoji/home/note_tile_comfortable.dart';
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/models/note_settings.dart';
import 'package:xiaoji/theme/app_theme.dart';

/// 主页在不同机型上的布局回归。
///
/// 用户反馈「有些手机上主页不好看」：复现出来的是 320dp 窄屏 + 系统
/// 大字号时，标题栏的「标题 + 标签胶囊 + 两个动作图标」会横向溢出，
/// 右侧图标被裁掉（或出现黄黑报错条）。这里把常见手机宽度（320 / 360 /
/// 412dp）与字号缩放（1.0 / 1.3 / 1.5）交叉覆盖，任何 RenderFlex 溢出
/// 都会让用例失败。
Future<void> _pumpFrames(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<NoteRepository> _createRepository(
  WidgetTester tester,
  ListDensity density, {
  bool withActiveTag = true,
  bool showBackupTip = false,
}) async {
  final Directory tempDir = Directory.systemTemp.createTempSync('xiaoji_home_');
  addTearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });
  late NoteRepository repository;
  await tester.runAsync(() async {
    final NoteStore store =
        await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
    repository = NoteRepository(store);
    await repository.load();
    await repository.upsert(
      Note(
        id: 'n1',
        created: DateTime(2026, 11, 1, 9),
        updated: DateTime(2026, 11, 1, 10),
        // 长标签名：顶栏胶囊和卡片 chip 都必须能截断而不是撑破布局。
        tags: const <String>['一个很长很长的标签名字', '工作', '第三'],
        body: '今天把主页在不同尺寸手机上的布局重新过了一遍，确保窄屏也不会挤。'
            '\n\n| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |',
      ),
    );
    await repository.upsert(
      Note(
        id: 'n2',
        created: DateTime(2026, 10, 30, 9),
        updated: DateTime(2026, 10, 30, 18),
        tags: const <String>['想法'],
        body: '第二条',
      ),
    );
    await repository.updateSettings(
      repository.settings.copyWith(
        density: density,
        backupTipShown: !showBackupTip,
      ),
    );
    if (withActiveTag) {
      repository.setActiveTag('一个很长很长的标签名字');
    }
  });
  return repository;
}

Future<void> _pumpHome(
  WidgetTester tester,
  NoteRepository repository,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: HomePage(repository: repository),
    ),
  );
  await _pumpFrames(tester);
}

void main() {
  final List<(double, double)> cases = <(double, double)>[
    (320, 1.0),
    (320, 1.3),
    (320, 1.5),
    (360, 1.3),
    (412, 1.0),
  ];

  for (final ListDensity density in ListDensity.values) {
    for (final (double width, double scale) in cases) {
      testWidgets(
        '${width.toInt()}dp x $scale 字号（$density）主页不溢出',
        (tester) async {
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1.0;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

          final NoteRepository repository =
              await _createRepository(tester, density);
          await _pumpHome(tester, repository);

          expect(find.text('小记'), findsOneWidget);
          // 顶栏胶囊 + 卡片标签（舒适档）都会出现，至少有一个即可。
          expect(find.text('#一个很长很长的标签名字'), findsWidgets);
        },
      );
    }
  }

  testWidgets('320dp + 1.3 字号：备份提示可见时也不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final NoteRepository repository = await _createRepository(
      tester,
      ListDensity.comfortable,
      withActiveTag: false,
      showBackupTip: true,
    );
    await _pumpHome(tester, repository);

    expect(find.text('数据只存在这台手机'), findsOneWidget);
  });

  testWidgets('320dp 窄屏页边距收到 12，标题与卡片左缘对齐', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final NoteRepository repository =
        await _createRepository(tester, ListDensity.comfortable);
    await _pumpHome(tester, repository);

    expect(tester.getTopLeft(find.text('小记')).dx, 12);
    expect(tester.getTopLeft(find.byType(NoteTileComfortable).first).dx, 12);
  });

  testWidgets('360dp 页边距保持 16', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final NoteRepository repository =
        await _createRepository(tester, ListDensity.comfortable);
    await _pumpHome(tester, repository);

    expect(tester.getTopLeft(find.text('小记')).dx, 16);
    expect(tester.getTopLeft(find.byType(NoteTileComfortable).first).dx, 16);
  });
}
