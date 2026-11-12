import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/models/note.dart';

/// 构造一条笔记；id 手工给，避免依赖随机数。
Note _note(
  String id, {
  String body = '',
  List<String> tags = const <String>[],
  bool pinned = false,
  DateTime? updated,
}) {
  final created = DateTime(2026, 10, 31, 9, 0);
  return Note(
    id: id,
    created: created,
    updated: updated ?? created,
    tags: tags,
    pinned: pinned,
    body: body,
  );
}

void main() {
  late Directory tempDir;
  late NoteStore store;
  late NoteRepository repo;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('xiaoji_repo_');
    store = await NoteStore.openAt(tempDir);
    repo = NoteRepository(store);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<void> seed(List<Note> notes) async {
    for (final note in notes) {
      await store.saveNote(note);
    }
    await repo.load();
  }

  group('边界：搜索', () {
    test('英文关键字大小写不敏感', () async {
      await seed(<Note>[
        _note('a', body: 'Hello Flutter World'),
        _note('b', body: '今天去了西湖'),
      ]);

      repo.setQuery('flutter');
      expect(repo.visibleNotes.map((note) => note.id), <String>['a']);

      repo.setQuery('FLUTTER');
      expect(repo.visibleNotes.map((note) => note.id), <String>['a']);
    });

    test('命中标签名', () async {
      await seed(<Note>[
        _note('a', body: '正文和关键字无关', tags: const <String>['旅行']),
        _note('b', body: '也不相关'),
      ]);
      repo.setQuery('旅行');
      expect(repo.visibleNotes.map((note) => note.id), <String>['a']);
    });

    test('命中正文中文片段', () async {
      await seed(<Note>[
        _note('a', body: '今天去了西湖，人很多'),
        _note('b', body: '明天开会'),
      ]);
      repo.setQuery('西湖');
      expect(repo.visibleNotes.map((note) => note.id), <String>['a']);
    });

    test('空查询返回全部且 isSearching 为 false', () async {
      await seed(<Note>[_note('a', body: 'x'), _note('b', body: 'y')]);
      repo.setQuery('');
      expect(repo.visibleNotes.length, 2);
      expect(repo.isSearching, isFalse);
    });

    test('纯空格查询返回全部且 isSearching 为 false', () async {
      await seed(<Note>[_note('a', body: 'x'), _note('b', body: 'y')]);
      repo.setQuery('   ');
      expect(repo.visibleNotes.length, 2);
      expect(repo.isSearching, isFalse);
    });

    test('搜索无命中时结果为空', () async {
      await seed(<Note>[_note('a', body: 'x')]);
      repo.setQuery('不存在的词');
      expect(repo.visibleNotes, isEmpty);
    });

    test('空白正文的笔记不会因为摘要判空而误命中', () async {
      await seed(<Note>[
        _note('empty', body: '   \n\t '),
        _note('text', body: '有内容'),
      ]);
      repo.setQuery('   ');
      expect(repo.visibleNotes.length, 2);
    });
  });

  group('边界：标签筛选', () {
    test('标签筛选叠加搜索关键字', () async {
      await seed(<Note>[
        _note('a', body: '会议记录', tags: const <String>['工作']),
        _note('b', body: '会议记录', tags: const <String>['生活']),
        _note('c', body: '随手一记', tags: const <String>['工作']),
      ]);

      repo.setActiveTag('工作');
      expect(repo.visibleNotes.map((note) => note.id).toSet(), <String>{'a', 'c'});

      repo.setQuery('会议');
      expect(repo.visibleNotes.map((note) => note.id), <String>['a']);

      repo.setQuery('');
      repo.setActiveTag(null);
      expect(repo.visibleNotes.length, 3);
    });

    test('筛选到不存在的标签时结果为空', () async {
      await seed(<Note>[_note('a', body: 'x', tags: const <String>['工作'])]);
      repo.setActiveTag('不存在');
      expect(repo.visibleNotes, isEmpty);
    });

    test('标签云按出现次数降序、次数相同按名称升序', () async {
      await seed(<Note>[
        _note('a', tags: const <String>['a', 'b']),
        _note('b', tags: const <String>['a']),
        _note('c', tags: const <String>['b', 'c']),
      ]);
      expect(repo.tags, <String>['a', 'b', 'c']);
    });

    test('没有标签时标签云为空', () async {
      await seed(<Note>[_note('a', body: 'x')]);
      expect(repo.tags, isEmpty);
    });
  });

  group('边界：排序', () {
    test('置顶优先，其余按 updated 倒序', () async {
      // 读盘时 updated 不会早于 created（Note.decode 会夹紧），
      // 这里的时间都要晚于 _note 默认的 created。
      await seed(<Note>[
        _note('old', body: 'old', updated: DateTime(2026, 11, 1)),
        _note('new', body: 'new', updated: DateTime(2026, 11, 5)),
        _note(
          'pinnedOld',
          body: 'pinned',
          pinned: true,
          updated: DateTime(2026, 10, 31, 10),
        ),
      ]);
      expect(
        repo.visibleNotes.map((note) => note.id).toList(),
        <String>['pinnedOld', 'new', 'old'],
      );
    });

    test('两条都置顶时按 updated 倒序', () async {
      await seed(<Note>[
        _note('p1', body: '1', pinned: true, updated: DateTime(2026, 11, 2)),
        _note('p2', body: '2', pinned: true, updated: DateTime(2026, 11, 9)),
      ]);
      expect(
        repo.visibleNotes.map((note) => note.id).toList(),
        <String>['p2', 'p1'],
      );
    });

    test('updated 相同时按 id 升序，顺序稳定', () async {
      final DateTime same = DateTime(2026, 11, 5);
      await seed(<Note>[
        _note('b', body: 'b', updated: same),
        _note('c', body: 'c', updated: same),
        _note('a', body: 'a', updated: same),
      ]);
      expect(
        repo.visibleNotes.map((note) => note.id).toList(),
        <String>['a', 'b', 'c'],
      );
    });
  });

  group('边界：内存视图', () {
    test('notes 返回不可修改列表', () async {
      await seed(<Note>[_note('a', body: 'x')]);
      expect(repo.notes, isA<List<Note>>());
      expect(() => repo.notes.add(_note('x')), throwsUnsupportedError);
    });

    test('upsert 新笔记后立即出现在可见列表里', () async {
      await seed(<Note>[]);
      await repo.upsert(_note('n1', body: '新笔记'));
      expect(repo.visibleNotes.map((note) => note.id), <String>['n1']);
      expect(await store.loadNotes(), hasLength(1));
    });

    test('load 之前 isLoading 为 true，之后为 false', () async {
      expect(repo.isLoading, isTrue);
      await repo.load();
      expect(repo.isLoading, isFalse);
    });

    test('togglePin 会翻转置顶状态', () async {
      await seed(<Note>[_note('a', body: 'x')]);
      final updated = await repo.togglePin(repo.visibleNotes.single);
      expect(updated.pinned, isTrue);
      expect(repo.visibleNotes.single.pinned, isTrue);
    });

    test('togglePin 不改 updated（置顶不算内容更新）', () async {
      final DateTime updatedAt = DateTime(2026, 11, 5, 8, 30);
      await seed(<Note>[_note('a', body: 'x', updated: updatedAt)]);

      final Note pinned = await repo.togglePin(repo.visibleNotes.single);
      expect(pinned.pinned, isTrue);
      expect(pinned.updated, updatedAt, reason: '置顶不能刷新「最近更新」时间');

      final Note unpinned = await repo.togglePin(pinned);
      expect(unpinned.pinned, isFalse);
      expect(unpinned.updated, updatedAt, reason: '取消置顶也不能刷新更新时间');
    });
  });
}
