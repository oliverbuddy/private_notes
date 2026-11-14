import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/util/backup_crypto.dart';

/// 备份增强的回归：
///  - 新备份包写入 manifest.json，恢复前能读出「哪一天 / 多少篇 / 多少图」；
///  - 旧包没有 manifest 时按条目名扫描计数，不阻断恢复；
///  - 加密包用文件头识别，口令错误映射成明确异常。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late NoteStore store;
  late NoteRepository repository;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('xiaoji_manifest_');
    store = await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
    repository = NoteRepository(store);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('xiaoji/native'), null);
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Note note(String id, {String body = '正文'}) => Note(
        id: id,
        created: DateTime(2026, 11, 13, 9),
        updated: DateTime(2026, 11, 13, 9),
        body: body,
      );

  Future<void> seed() async {
    await repository.upsert(note('20261113-0900-a'));
    await repository.upsert(note('20261113-0900-b'));
    final asset = File('${store.assetsDir.path}/20261113-0900-a/1.png');
    await asset.parent.create(recursive: true);
    await asset.writeAsBytes(<int>[1, 2, 3]);
  }

  test('手动备份写入 manifest，可读出摘要', () async {
    await seed();
    final File backup =
        await store.createBackupFile(name: 'manual-20261113-0900.zip');

    final BackupSummary summary = await store.inspectBackupFile(backup.path);
    expect(summary.hasManifest, isTrue);
    expect(summary.noteCount, 2, reason: '两篇笔记都进包并计数');
    expect(summary.assetCount, 1);
    expect(summary.encrypted, isFalse);
    expect(summary.createdAt, isNotNull);

    // manifest 必须真的在 zip 里，而不是只算了数。
    final Archive archive = ZipDecoder().decodeBytes(backup.readAsBytesSync());
    final ArchiveFile manifest = archive.files
        .singleWhere((ArchiveFile file) => file.name == 'manifest.json');
    final Map<String, dynamic> decoded =
        jsonDecode(utf8.decode(manifest.content as List<int>))
            as Map<String, dynamic>;
    expect(decoded['schema'], NoteStore.backupSchemaVersion);
    expect(decoded['kind'], 'manual');
    expect(decoded['app'], 'xiaoji');
    expect(decoded['noteCount'], 2);
  });

  test('旧包没有 manifest 时按条目计数，不阻断恢复', () async {
    final Note legacyNote = note('20261113-0900-legacy');
    final String encoded = legacyNote.encode();
    final Archive archive = Archive()
      ..addFile(ArchiveFile(
        'notes/2026/11/20261113-0900-legacy.md',
        encoded.length,
        utf8.encode(encoded),
      ))
      ..addFile(ArchiveFile('assets/20261113-0900-legacy/1.png', 3, <int>[
        1,
        2,
        3,
      ]));
    final File legacy = File('${tempDir.path}/legacy.zip')
      ..writeAsBytesSync(Uint8List.fromList(ZipEncoder().encode(archive)!));

    final BackupSummary summary = await store.inspectBackupFile(legacy.path);
    expect(summary.hasManifest, isFalse);
    expect(summary.createdAt, isNull);
    expect(summary.noteCount, 1);
    expect(summary.assetCount, 1);
    expect(summary.label, '1 篇 · 1 张图');
  });

  test('导出 manifest：加密标记与真实条目数一致', () async {
    await seed();
    // 内存版导出的 manifest 计数以真正写进包的条目为准。
    final Uint8List bytes = await store.buildExportZip(
      manifestJson: jsonEncode(<String, Object?>{
        'schema': NoteStore.backupSchemaVersion,
        'createdAt': '2026-11-13T01:00:00.000',
        'kind': 'export',
        'encrypted': true,
        'noteCount': 999,
        'assetCount': 999,
      }),
    );
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    final ArchiveFile manifest = archive.files
        .singleWhere((ArchiveFile file) => file.name == 'manifest.json');
    final Map<String, dynamic> decoded =
        jsonDecode(utf8.decode(manifest.content as List<int>))
            as Map<String, dynamic>;
    expect(decoded['encrypted'], isTrue);
    expect(decoded['noteCount'], 2, reason: '以真实打包条目为准，不信调用方预估');
    expect(decoded['assetCount'], 1);
  });

  test('加密包按文件头识别，普通 zip 不受影响', () async {
    final File plain = File('${tempDir.path}/plain.zip')
      ..writeAsStringSync('PK\u0003\u0004not-really');
    expect(await isEncryptedBackup(plain.path), isFalse);

    final File encrypted = File('${tempDir.path}/encrypted.xiaoji')
      ..writeAsStringSync('$backupEncryptedMagic${'x' * 40}');
    expect(await isEncryptedBackup(encrypted.path), isTrue);

    final File tooShort = File('${tempDir.path}/short.bin')
      ..writeAsStringSync('XJ');
    expect(await isEncryptedBackup(tooShort.path), isFalse);
  });

  test('口令错误映射成 BackupPasswordException', () async {
    const MethodChannel channel = MethodChannel('xiaoji/native');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'decryptFile') {
        throw PlatformException(
          code: 'bad_password',
          message: '口令不正确或文件已损坏',
        );
      }
      return null;
    });

    await expectLater(
      decryptBackupFile(
        sourcePath: '${tempDir.path}/a.xiaoji',
        targetPath: '${tempDir.path}/a.zip',
        password: '123456',
      ),
      throwsA(isA<BackupPasswordException>()),
    );
  });

  test('BackupSummary 容错：坏 manifest 回落到扫描计数', () {
    final BackupSummary bad = BackupSummary.fromManifest(
      'not-json',
      noteCount: 3,
      assetCount: 2,
    );
    expect(bad.hasManifest, isFalse);
    expect(bad.label, '3 篇 · 2 张图');

    final BackupSummary parsed = BackupSummary.fromManifest(
      jsonEncode(<String, Object?>{
        'createdAt': '2026-11-13T01:00:00.000',
        'noteCount': 32,
        'assetCount': 48,
        'encrypted': false,
      }),
      noteCount: 0,
      assetCount: 0,
    );
    expect(parsed.hasManifest, isTrue);
    expect(parsed.label, startsWith('2026-11-13 · 32 篇 · 48 张图'));
  });
}
