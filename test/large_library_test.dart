import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/home/home_page.dart';
import 'package:xiaoji/home/note_tile_comfortable.dart';
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/theme/app_theme.dart';

/// 大库回归：本地存了几千条笔记时，主页读列表不能每次 rebuild 都全量
/// 过滤 + 排序，首屏也只应构建可见的条目。
void main() {
  const int total = 2000;
  late Directory tempDir;
  late NoteStore store;
  late NoteRepository repo;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('xiaoji_large_');
    store = await NoteStore.openAt(Directory(p.join(tempDir.path, 'Xiaoji')));
    repo = NoteRepository(store);
    final DateTime base = DateTime(2026, 1, 1, 8);
    for (var i = 0; i < total; i++) {
      await store.saveNote(
        Note(
          id: 'n${i.toString().padLeft(4, '0')}',
          created: base.add(Duration(minutes: i)),
          updated: base.add(Duration(minutes: i)),
          body: '第 $i 条笔记\n\n正文内容 $i',
        ),
      );
    }
    await repo.load();
  });

  tearDownAll(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('visibleNotes 命中缓存：同一次数据版本只排序一次', () {
    final List<Note> first = repo.visibleNotes;
    final List<Note> second = repo.visibleNotes;

    expect(first.length, total);
    // 同一实例 = 第二次没有再走 where + sort。
    expect(identical(first, second), isTrue);
    // 最新更新的一条排最前。
    expect(first.first.id, 'n1999');
    expect(first.last.id, 'n0000');
  });

  test('筛选 / 排序变化会让缓存失效', () {
    final List<Note> all = repo.visibleNotes;
    repo.setActiveTag('不存在的标签');
    expect(repo.visibleNotes, isEmpty);
    repo.setActiveTag(null);
    final List<Note> restored = repo.visibleNotes;
    expect(restored.length, all.length);
    // 失效后重新生成的列表不能复用上一份实例。
    expect(identical(restored, all), isFalse);
  });

  testWidgets('2000 条笔记的首屏只构建可见条目且不抛异常', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: HomePage(repository: repo),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    expect(tester.takeException(), isNull);
    // ListView.builder 懒构建：一屏只应有十几个卡片，而不是 2000 个。
    final int built = tester.widgetList<NoteTileComfortable>(
      find.byType(NoteTileComfortable),
    ).length;
    expect(built, greaterThan(0));
    expect(built, lessThan(40));
  });
}
