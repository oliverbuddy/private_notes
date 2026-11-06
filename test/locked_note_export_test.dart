import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/models/note_settings.dart';

/// 单篇锁定相关的存储行为回归：
///  - 落盘正文必须是密文信封，明文不出现在 .md 里；
///  - 内存里正文置空后只改元数据（置顶/标签）不能把密文覆盖掉；
///  - 导出 zip 默认排除锁定笔记（正文与附件都不进包）。
///
/// 原生通道用 mock 替代：测试环境没有 Keystore，只关心信封格式与排除逻辑。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('xiaoji/native');

  late Directory tempDir;
  late NoteStore store;
  var envelopeCounter = 0;

  void mockChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      switch (call.method) {
        case 'sealText':
          envelopeCounter += 1;
          return 'cipher-$envelopeCounter';
        case 'openText':
          return '明文正文';
        case 'isDeviceSecure':
          return false;
        default:
          return null;
      }
    });
  }

  setUp(() async {
    envelopeCounter = 0;
    mockChannel();
    tempDir = Directory.systemTemp.createTempSync('xiaoji_lock_');
    store = await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Note lockedNote() => Note(
        id: '20261106-0100-lock',
        created: DateTime(2026, 11, 6, 1),
        updated: DateTime(2026, 11, 6, 1),
        locked: true,
        body: '机密正文',
      );

  Note normalNote() => Note(
        id: '20261106-0100-open',
        created: DateTime(2026, 11, 6, 1),
        updated: DateTime(2026, 11, 6, 1),
        body: '普通正文',
      );

  Future<void> writeAsset(String noteId) async {
    final file = File('${store.assetsDir.path}/$noteId/1.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(<int>[1, 2, 3]);
  }

  test('锁定笔记落盘为密文信封，明文不落盘', () async {
    await store.saveNote(lockedNote());
    final raw = File(store.pathFor(lockedNote())).readAsStringSync();
    expect(raw, contains('locked: true'));
    expect(raw, contains(Note.lockEnvelopePrefix));
    expect(raw, isNot(contains('机密正文')));
  });

  test('内存正文为空时只改元数据，不覆盖已有密文', () async {
    await store.saveNote(lockedNote());
    final before = File(store.pathFor(lockedNote())).readAsStringSync();
    expect(before, contains('cipher-1'));

    // 模拟列表里拿到的锁定笔记（正文已被置空），只改置顶状态。
    await store.saveNote(lockedNote().copyWith(body: '', pinned: true));

    final after = File(store.pathFor(lockedNote())).readAsStringSync();
    expect(after, contains('cipher-1'), reason: '沿用原密文，不再加密一次');
    expect(after, isNot(contains('cipher-2')), reason: '没有重新加密空正文');
    expect(after, contains('pinned: true'));
  });

  test('导出默认排除锁定笔记的正文与附件', () async {
    await store.saveNote(lockedNote());
    await store.saveNote(normalNote());
    await writeAsset(lockedNote().id);
    await writeAsset(normalNote().id);

    final bytes = await store.buildExportZip(
      excludeNoteIds: <String>{lockedNote().id},
    );
    final archive = ZipDecoder().decodeBytes(bytes);
    final names = archive.files.map((ArchiveFile file) => file.name).toList();

    expect(names, contains('20261106-0100-open.md'));
    expect(names, contains('assets/20261106-0100-open/1.png'));
    expect(names, isNot(contains('20261106-0100-lock.md')));
    expect(
      names.where((String name) => name.contains(lockedNote().id)),
      isEmpty,
      reason: '锁定笔记的附件目录一并排除',
    );
  });

  test('加密的正文能按 id 解密读回', () async {
    await store.saveNote(lockedNote());
    final body = await store.readNoteBody(lockedNote());
    expect(body, '明文正文');
  });

  test('私有备份包含锁定笔记（同机可恢复），导出仍排除', () async {
    await store.saveNote(lockedNote());

    List<String> capturedExcludes = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'zipTree') {
        capturedExcludes = (call.arguments['excludes'] as List<Object?>)
            .cast<String>();
        // createBackupFile 随后会 rename 这个临时文件，mock 里先落一个占位。
        final String target = call.arguments['targetPath'] as String;
        File(target).writeAsStringSync('dummy-zip');
        return target;
      }
      return null;
    });

    await store.createBackupFile(name: 'manual-test.zip');
    expect(
      capturedExcludes,
      containsAll(<String>['backups', 'trash', 'tmp']),
      reason: '备份仍然不包含旧备份/回收站/临时目录',
    );
    expect(
      capturedExcludes,
      isNot(contains('notes/2026/11/${lockedNote().id}.md')),
      reason: '锁定笔记的密文要进备份，才能在同机误删后恢复',
    );
    expect(
      capturedExcludes,
      isNot(contains('assets/${lockedNote().id}')),
    );
  });

  test('导出参数：排除 trash/backups，settings 脱敏，明文导出写解密正文', () async {
    await store.saveNote(lockedNote());
    await store.saveNote(normalNote());
    await store.saveSettings(
      const NoteSettings(
        lockEnabled: true,
        pinHash: 'SECRET-HASH',
        pinSalt: 'SECRET-SALT',
      ),
    );

    List<String> excludes = <String>[];
    Map<String, String> overrides = <String, String>{};
    // 覆盖文件在 buildExportZipToFile 的 finally 里会被删除，必须在
    // 调用原生压缩的当下把内容读出来。
    Map<String, String> overrideContents = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'zipTree') {
        excludes = (call.arguments['excludes'] as List<Object?>)
            .cast<String>();
        overrides = (call.arguments['overrides'] as Map<Object?, Object?>)
            .map((Object? key, Object? value) =>
                MapEntry<String, String>(key! as String, value! as String));
        overrideContents = overrides.map(
          (String key, String path) =>
              MapEntry<String, String>(key, File(path).readAsStringSync()),
        );
        return null;
      }
      if (call.method == 'sealText') {
        envelopeCounter += 1;
        return 'cipher-$envelopeCounter';
      }
      if (call.method == 'openText') {
        return '明文正文';
      }
      return null;
    });

    final tempDir = Directory.systemTemp.createTempSync('xiaoji_export_');
    try {
      // 默认导出：排除回收站/旧备份/临时目录 + 锁定笔记正文与附件。
      final out = File('${tempDir.path}/default.zip');
      await store.buildExportZipToFile(out.path);
      expect(excludes, containsAll(<String>[
        'trash',
        'backups',
        'tmp',
        'notes/2026/11/${lockedNote().id}.md',
        'assets/${lockedNote().id}',
      ]));

      // 导出包里的 settings 必须是脱敏版：不含 PIN 哈希/盐。
      final redacted = overrideContents['settings.json'];
      expect(redacted, isNotNull);
      expect(redacted, isNot(contains('SECRET-HASH')));
      expect(redacted, isNot(contains('SECRET-SALT')));
      expect(redacted, isNot(contains('pinHash')));

      // 明文导出：锁定笔记的条目被替换成解密后的正文。
      final plainOut = File('${tempDir.path}/plain.zip');
      await store.buildExportZipToFile(plainOut.path, includeLocked: true);
      final plain = overrideContents['notes/2026/11/${lockedNote().id}.md'];
      expect(plain, isNotNull);
      expect(plain, contains('明文正文'));
      expect(plain, isNot(contains('locked: true')));
      expect(plain, isNot(contains(Note.lockEnvelopePrefix)));
    } finally {
      tempDir.deleteSync(recursive: true);
    }
  });
}
