import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/models/note.dart';

/// 备份恢复的「快照」语义：恢复后，备份里出现的笔记应当回到导出时的
/// 状态——包括附件目录，不能在本地留下导出之后新增/删除的旧图。
Uint8List _zip(Map<String, List<int>> entries) {
  final Archive archive = Archive();
  for (final MapEntry<String, List<int>> entry in entries.entries) {
    archive.addFile(
      ArchiveFile(entry.key, entry.value.length, entry.value),
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

Note _note(String id, {String body = ''}) {
  final DateTime time = DateTime(2026, 11, 10, 10);
  return Note(id: id, created: time, updated: time, body: body);
}

void main() {
  late Directory tempDir;
  late NoteStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('xiaoji_restore_');
    store = await NoteStore.openAt(Directory(p.join(tempDir.path, 'Xiaoji')));
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('恢复笔记时附件目录整体替换，删掉备份后新增的旧图', () async {
    await store.saveNote(_note('a', body: '旧正文'));
    final Directory assets = store.assetDirectoryOf('a');
    await assets.create(recursive: true);
    final File extra = File(p.join(assets.path, 'extra.png'));
    await extra.writeAsBytes(<int>[1, 2, 3]);

    final Uint8List bytes = _zip(<String, List<int>>{
      'notes/2026-11/a.md': utf8Bytes(
        _note('a', body: '快照正文 ![x](assets/a/1.png)').encode(),
      ),
      'assets/a/1.png': <int>[9, 9, 9],
    });

    final (int restored, int skipped) = await store.restoreFromZip(bytes);

    expect(restored, 1);
    expect(skipped, 0);
    expect(await extra.exists(), isFalse);
    expect(
      await File(p.join(assets.path, '1.png')).exists(),
      isTrue,
    );
    final Note loaded = (await store.loadNotes()).single;
    expect(loaded.body, contains('快照正文'));
  });

  test('备份里该笔记没有附件时，本地旧附件也会清空', () async {
    await store.saveNote(_note('b', body: '旧正文'));
    final Directory assets = store.assetDirectoryOf('b');
    await assets.create(recursive: true);
    final File old = File(p.join(assets.path, 'old.png'));
    await old.writeAsBytes(<int>[7]);

    final Uint8List bytes = _zip(<String, List<int>>{
      'notes/2026-11/b.md': utf8Bytes(_note('b', body: '纯文字快照').encode()),
    });

    final (int restored, _) = await store.restoreFromZip(bytes);

    expect(restored, 1);
    expect(await old.exists(), isFalse);
    expect(await assets.exists(), isFalse);
  });

  test('备份之外的本地笔记与附件不受影响', () async {
    await store.saveNote(_note('keep', body: '本地新笔记'));
    final Directory keepAssets = store.assetDirectoryOf('keep');
    await keepAssets.create(recursive: true);
    final File keepImage = File(p.join(keepAssets.path, 'keep.png'));
    await keepImage.writeAsBytes(<int>[5, 5]);

    final Uint8List bytes = _zip(<String, List<int>>{
      'notes/2026-11/a.md': utf8Bytes(_note('a', body: '备份里的笔记').encode()),
    });
    await store.restoreFromZip(bytes);

    expect(await keepImage.exists(), isTrue);
    expect(
      (await store.loadNotes()).map((Note note) => note.id),
      containsAll(<String>['a', 'keep']),
    );
  });

  test('只有附件没有正文的异常包：只合并，不删本地文件', () async {
    await store.saveNote(_note('c', body: '正文'));
    final Directory assets = store.assetDirectoryOf('c');
    await assets.create(recursive: true);
    final File local = File(p.join(assets.path, 'local.png'));
    await local.writeAsBytes(<int>[1]);

    final Uint8List bytes = _zip(<String, List<int>>{
      'assets/c/from-backup.png': <int>[2, 2],
    });
    final (int restored, _) = await store.restoreFromZip(bytes);

    expect(restored, 0);
    expect(await local.exists(), isTrue);
    expect(
      await File(p.join(assets.path, 'from-backup.png')).exists(),
      isTrue,
    );
  });
}

List<int> utf8Bytes(String value) => utf8.encode(value);
