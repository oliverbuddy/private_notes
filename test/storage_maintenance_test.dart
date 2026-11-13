import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/models/note.dart';

/// 存储维护：占用统计、未引用附件清理、外部 Markdown 导入。
///
/// 清理是不可逆操作，这里重点验证「宁可少删」的保护规则：
///  - 正文仍引用的附件不删；
///  - 历史版本引用的附件不删；
///  - 锁定笔记（正文是密文）整个目录不删；
///  - 回收站里的附件不碰；
///  - 只删 assets/ 下的普通文件，空目录顺手收走。
Note _note(
  String id, {
  String body = '',
  List<String> tags = const <String>[],
  DateTime? created,
  bool locked = false,
}) {
  final DateTime time = created ?? DateTime(2026, 11, 1, 9);
  return Note(
    id: id,
    created: time,
    updated: time,
    tags: tags,
    locked: locked,
    body: body,
  );
}

Future<File> _writeAsset(
  NoteStore store,
  String noteId,
  String name,
  int bytes,
) async {
  final Directory dir = store.assetDirectoryOf(noteId);
  await dir.create(recursive: true);
  final File file = File(p.join(dir.path, name));
  await file.writeAsBytes(List<int>.filled(bytes, 7));
  return file;
}

void main() {
  late Directory tempDir;
  late NoteStore store;
  late NoteRepository repo;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('xiaoji_storage_');
    store = await NoteStore.openAt(tempDir);
    repo = NoteRepository(store);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('清理未使用附件', () {
    test('删除没有被正文引用的文件，保留仍被引用的文件', () async {
      await store.saveNote(_note('a', body: '看图 ![x](assets/a/used.png)'));
      final File used = await _writeAsset(store, 'a', 'used.png', 128);
      final File orphan = await _writeAsset(store, 'a', 'orphan.png', 256);

      final OrphanCleanupResult result = await store.cleanUnusedAssets();

      expect(result.files, 1);
      expect(result.bytes, 256);
      expect(await used.exists(), isTrue);
      expect(await orphan.exists(), isFalse);
    });

    test('历史版本里引用的附件不删（恢复旧版本不能裂图）', () async {
      await store.saveNote(
        _note('b', body: '旧版 ![x](assets/b/old.png)'),
      );
      await store.saveNote(_note('b', body: '新版没有图了'));
      final File old = await _writeAsset(store, 'b', 'old.png', 64);

      final OrphanCleanupResult result = await store.cleanUnusedAssets();

      expect(result.files, 0);
      expect(await old.exists(), isTrue);
    });

    test('锁定笔记整个附件目录跳过（正文是密文，解析不出引用）', () async {
      final Note locked = _note('c', locked: true, body: '密文');
      await store.saveLockedEnvelope(locked, 'ciphertext');
      final File file = await _writeAsset(store, 'c', 'photo.jpg', 512);

      final OrphanCleanupResult result = await store.cleanUnusedAssets();

      expect(result.files, 0);
      expect(result.lockedSkipped, 1);
      expect(await file.exists(), isTrue);
    });

    test('回收站里的附件不参与清理', () async {
      final Note note = _note('d', body: '正文');
      await store.saveNote(note);
      await _writeAsset(store, 'd', 'kept.png', 32);
      await store.deleteNote(note);

      final OrphanCleanupResult result = await store.cleanUnusedAssets();

      expect(result.files, 0);
      // 附件整目录改名成 trash/<id>/assets/，不保留 notes 下的原路径。
      final Directory trashed =
          Directory(p.join(store.trashDir.path, 'd', 'assets'));
      expect(
        await File(p.join(trashed.path, 'kept.png')).exists(),
        isTrue,
      );
    });

    test('清空的附件目录会被删掉', () async {
      await store.saveNote(_note('e', body: '没有图'));
      await _writeAsset(store, 'e', 'lonely.png', 8);

      await store.cleanUnusedAssets();

      expect(await store.assetDirectoryOf('e').exists(), isFalse);
    });

    test('没有任何附件时是空操作', () async {
      await store.saveNote(_note('f', body: '纯文字'));
      final OrphanCleanupResult result = await store.cleanUnusedAssets();
      expect(result.isEmpty, isTrue);
      expect(result.lockedSkipped, 0);
    });
  });

  group('存储占用统计', () {
    test('分类统计到正文、附件与回收站', () async {
      await store.saveNote(_note('g', body: '正文内容'));
      await _writeAsset(store, 'g', 'one.png', 100);
      final Note trashed = _note('h', body: '将被删除');
      await store.saveNote(trashed);
      await _writeAsset(store, 'h', 'two.png', 50);
      await store.deleteNote(trashed);

      final StorageUsage usage = await store.measureStorage();

      expect(usage.notes, greaterThan(0));
      expect(usage.assets, 100);
      expect(usage.trash, greaterThanOrEqualTo(50));
      expect(usage.total, greaterThanOrEqualTo(150));
    });
  });

  group('导入外部 Markdown', () {
    late Directory incoming;

    setUp(() async {
      incoming = Directory(p.join(tempDir.path, 'incoming'));
      await incoming.create(recursive: true);
    });

    test('没有 frontmatter 的文件整篇作为正文新建一条', () async {
      final File file = File(p.join(incoming.path, '随手记.md'));
      await file.writeAsString('# 标题\n\n第一段');

      final MarkdownImportResult result =
          await store.importMarkdownFiles(<String>[file.path]);

      expect(result.imported, 1);
      expect(result.skipped, 0);
      final List<Note> notes = await store.loadNotes();
      expect(notes, hasLength(1));
      expect(notes.single.body, contains('# 标题'));
      expect(notes.single.created, isNotNull);
    });

    test('带 frontmatter 的文件保留标签与创建时间', () async {
      final Note source = _note(
        'external-1',
        tags: <String>['导入', '测试'],
        created: DateTime(2026, 3, 5, 8),
        body: '来自其它编辑器的正文',
      );
      final File file = File(p.join(incoming.path, 'external.md'));
      await file.writeAsString(source.encode());

      final MarkdownImportResult result =
          await store.importMarkdownFiles(<String>[file.path]);

      expect(result.imported, 1);
      final List<Note> notes = await store.loadNotes();
      final Note imported =
          notes.firstWhere((Note note) => note.id == 'external-1');
      expect(imported.tags, <String>['导入', '测试']);
      expect(imported.created, DateTime(2026, 3, 5, 8));
      expect(imported.body, contains('来自其它编辑器'));
    });

    test('id 冲突时换新 id，不覆盖已有笔记', () async {
      await store.saveNote(_note('dup-1', body: '原有内容'));
      final File file = File(p.join(incoming.path, 'dup.md'));
      await file.writeAsString(
        _note('dup-1', body: '外来内容').encode(),
      );

      final MarkdownImportResult result =
          await store.importMarkdownFiles(<String>[file.path]);

      expect(result.imported, 1);
      expect(result.renamed, 1);
      final List<Note> notes = await store.loadNotes();
      expect(notes, hasLength(2));
      final Note original =
          notes.firstWhere((Note note) => note.id == 'dup-1');
      expect(original.body, contains('原有内容'));
    });

    test('别的设备加密的笔记跳过', () async {
      final File file = File(p.join(incoming.path, 'locked.md'));
      await file.writeAsString(
        _note('locked-1', locked: true, body: 'XIAOJI-LOCK-1:abc').encode(),
      );

      final MarkdownImportResult result =
          await store.importMarkdownFiles(<String>[file.path]);

      expect(result.imported, 0);
      expect(result.skipped, 1);
      expect(await store.loadNotes(), isEmpty);
    });

    test('不存在的文件计入跳过，不影响其它文件', () async {
      final File good = File(p.join(incoming.path, 'good.md'));
      await good.writeAsString('正常内容');

      final MarkdownImportResult result = await store.importMarkdownFiles(
        <String>[p.join(incoming.path, 'missing.md'), good.path],
      );

      expect(result.imported, 1);
      expect(result.skipped, 1);
    });

    test('仓库层导入后列表与搜索都能看到新笔记', () async {
      await repo.load();
      final File file = File(p.join(incoming.path, 'searchable.md'));
      await file.writeAsString('这是一条可以搜索的导入笔记');

      await repo.importMarkdownFiles(<String>[file.path]);

      expect(repo.visibleNotes, hasLength(1));
      repo.setQuery('可以搜索');
      expect(repo.visibleNotes, hasLength(1));
    });
  });
}
