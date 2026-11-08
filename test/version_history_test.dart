import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/models/note.dart';

Future<NoteStore> _createStore() async {
  final Directory temp = Directory.systemTemp.createTempSync('xiaoji_ver_');
  addTearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });
  return NoteStore.openAt(Directory('${temp.path}/Xiaoji'));
}

void main() {
  final DateTime base = DateTime(2026, 11, 8, 9, 0);

  test('首次保存不产生版本，改动后留上一版', () async {
    final NoteStore store = await _createStore();
    final Note first = Note(
      id: '20261108-0900-abcd',
      created: base,
      updated: base,
      body: '第一版',
    );
    await store.saveNote(first);
    expect(await store.listVersions(first.id), isEmpty);

    await store.saveNote(
      first.copyWith(updated: base.add(const Duration(minutes: 1)), body: '第二版'),
    );
    final List<NoteVersion> versions = await store.listVersions(first.id);
    expect(versions, hasLength(1));
    expect(await store.readVersion(versions.first), contains('第一版'));
  });

  test('正文没变不留版本', () async {
    final NoteStore store = await _createStore();
    final Note note = Note(
      id: 'n1',
      created: base,
      updated: base,
      body: '同样的正文',
    );
    await store.saveNote(note);
    await store.saveNote(note.copyWith(updated: base.add(const Duration(minutes: 1))));
    expect(await store.listVersions(note.id), isEmpty);
  });

  test('10 分钟内连续保存只留一版（节流）', () async {
    final NoteStore store = await _createStore();
    final Note note = Note(id: 'n2', created: base, updated: base, body: 'A');
    await store.saveNote(note);
    await store.saveNote(note.copyWith(body: 'B'));
    await store.saveNote(note.copyWith(body: 'C'));
    await store.saveNote(note.copyWith(body: 'D'));
    expect(await store.listVersions(note.id), hasLength(1));
  });

  test('恢复版本会先给当前内容留一版，正文回到旧版本', () async {
    final NoteStore store = await _createStore();
    final Note note = Note(id: 'n3', created: base, updated: base, body: 'A');
    await store.saveNote(note);
    await store.saveNote(note.copyWith(body: 'B'));
    final List<NoteVersion> versions = await store.listVersions(note.id);
    expect(versions, hasLength(1));

    final Note current = note.copyWith(body: 'B');
    final Note? restored = await store.restoreVersion(current, versions.first);
    expect(restored, isNotNull);
    expect(restored!.body, 'A');
    final String onDisk = await File(store.pathFor(current)).readAsString();
    expect(onDisk, contains('A'));

    // 恢复前的内容也留了一版，可再改回去。
    expect(await store.listVersions(note.id), hasLength(2));
  });

  test('锁定笔记的版本是密文，不含明文', () async {
    final NoteStore store = await _createStore();
    final Note locked = Note(
      id: 'n4',
      created: base,
      updated: base,
      locked: true,
      body: '${Note.lockEnvelopePrefix}AAA',
    );
    await store.saveNote(locked);
    await store.saveNote(
      locked.copyWith(body: '${Note.lockEnvelopePrefix}BBB'),
    );
    final NoteVersion version = (await store.listVersions(locked.id)).single;
    final String raw = await store.readVersion(version);
    expect(raw, contains('XIAOJI-LOCK-1:AAA'));
    expect(raw, isNot(contains('明文正文')));
  });

  test('删除时历史版本跟着进回收站，恢复后回来', () async {
    final NoteStore store = await _createStore();
    final Note note = Note(id: 'n5', created: base, updated: base, body: 'A');
    await store.saveNote(note);
    await store.saveNote(note.copyWith(body: 'B'));
    await store.deleteNote(note.copyWith(body: 'B'));
    expect(
      await Directory(store.versionDirectoryOf(note.id).path).exists(),
      isFalse,
      reason: '版本目录应随笔记一起进回收站，不能留在 versions/ 里',
    );

    final TrashedNote trashed = (await store.listTrash()).single;
    await store.restoreFromTrash(trashed);
    expect(await store.listVersions(note.id), isNotEmpty);
  });

  test('版本超过保留上限时自动清理', () async {
    final NoteStore store = await _createStore();
    final Note note = Note(id: 'n6', created: base, updated: base, body: 'v0');
    await store.saveNote(note);

    // 手工造 25 个同一天的合法版本文件。
    final Directory dir = store.versionDirectoryOf(note.id);
    await dir.create(recursive: true);
    for (var i = 0; i < 25; i++) {
      final String stamp =
          '2026110${i % 8}-10${(i % 60).toString().padLeft(2, '0')}0${i % 10}-${i.toString().padLeft(3, '0')}';
      await File('${dir.path}/$stamp.md').writeAsString('v$i');
    }
    // 触发一次快照（正文变化）→ 顺带执行保留策略。
    await store.saveNote(note.copyWith(body: 'v-new'));
    final List<NoteVersion> versions = await store.listVersions(note.id);
    expect(versions.length, lessThanOrEqualTo(21));
    expect(versions, isNotEmpty);
  });
}
