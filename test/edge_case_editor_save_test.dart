import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/editor/editor_page.dart';
import 'package:xiaoji/editor/markdown_view.dart';
import 'package:xiaoji/models/note.dart';

/// 缺陷 3 的回归：退出编辑页时的「补写」必须带上新的 updated，
/// 但没有任何改动时不该刷新 updated（否则列表顺序会莫名其妙地变）。
///
/// 注意两个坑：
/// 1. `testWidgets` 的 body 跑在 FakeAsync 里，真实文件 I/O 必须放进
///    `tester.runAsync`，否则 `await` 永不返回（会把整个 test 进程挂死）。
/// 2. dispose 里的补写是 `scheduleMicrotask` + 真实 I/O，是异步的，
///    断言前必须轮询等它落地，不能假设一帧之后就写完了。
void main() {
  const String noteId = '20260101-0000-aaaa';
  final DateTime originalUpdated = DateTime(2026, 1, 1, 8, 30);

  /// 轮询等待仓库里出现满足条件的笔记。
  ///
  /// 必须「runAsync 推进真实事件循环」与「pump 冲掉 FakeAsync 微任务」交替做：
  /// dispose 里的 upsert 是在 FakeAsync zone 里 `await` 真实文件 I/O 的，
  /// 它的续体排在 FakeAsync 的微任务队列里，只在 pump 时才被执行。
  Future<Note?> waitForNote(
    WidgetTester tester,
    NoteRepository repository,
    bool Function(Note note) test,
  ) async {
    for (var i = 0; i < 100; i++) {
      for (final note in repository.notes) {
        if (note.id == noteId && test(note)) {
          return note;
        }
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    return null;
  }

  Future<(NoteRepository, Note)> pumpEditor(WidgetTester tester) async {
    late NoteRepository repository;
    late Note seed;
    await tester.runAsync(() async {
      final tempDir = await Directory.systemTemp.createTemp('xiaoji_editor_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      final store = await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
      repository = NoteRepository(store);
      await repository.load();
      seed = Note(
        id: noteId,
        created: DateTime(2026, 1, 1, 8, 30),
        updated: originalUpdated,
        body: '原文',
      );
      await repository.upsert(seed);
    });

    await tester.pumpWidget(
      MaterialApp(home: EditorPage(repository: repository, note: seed)),
    );
    await tester.pump();

    // 已有笔记默认是阅读态，要打字必须先点进编辑态。
    await tester.tap(find.byType(MarkdownBlockView).first);
    await tester.pump();
    await tester.pump();
    return (repository, seed);
  }

  testWidgets('打完字 600ms 内退出：正文保存且 updated 被刷新', (tester) async {
    final (repository, _) = await pumpEditor(tester);

    await tester.enterText(find.byType(TextField).first, '改过的内容');
    await tester.pump(); // 故意不推进 600ms，模拟用户打完就返回

    // 把编辑页从树上摘掉，触发 dispose 里的补写。
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await tester.pump();

    final saved = await waitForNote(
      tester,
      repository,
      (note) => note.body == '改过的内容',
    );

    expect(saved, isNotNull, reason: '退出时必须把正文补写到磁盘并刷新内存视图');
    expect(
      saved!.updated.isAfter(originalUpdated),
      isTrue,
      reason: '脏数据退出时必须刷新 updated，否则列表里这条不会浮到顶部',
    );
  });

  testWidgets('没做任何修改就退出：updated 保持不变', (tester) async {
    final (repository, _) = await pumpEditor(tester);

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    await tester.pump();

    final saved = await waitForNote(
      tester,
      repository,
      (note) => note.body == '原文',
    );

    expect(saved, isNotNull);
    expect(
      saved!.updated,
      originalUpdated,
      reason: '只读不写不该刷新 updated，否则每次打开都会把它顶到最前面',
    );
  });
}
