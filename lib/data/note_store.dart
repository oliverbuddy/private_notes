import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/note.dart';
import '../models/note_settings.dart';
import '../security/security_service.dart';
import '../util/date_format.dart';
import '../util/native_zip.dart';
import 'search_index.dart';

/// 文件布局：
///
/// ```
/// <appDocuments>/Xiaoji/
///   notes/<yyyy>/<MM>/<id>.md
///   assets/<noteId>/1.jpg
///   trash/<noteId>/{note.md, assets/, meta.json}
///   backups/{auto-YYYYMMDD.zip, pre-restore-*.zip}
///   settings.json
/// ```
///
/// 说明：Android 上 `<appDocuments>` 是 `/data/user/0/<包名>/app_flutter`，
/// 属于应用私有目录，系统「文件」管理器看不到；换机/卸载前必须走「导出」。
class NoteStore {
  NoteStore._(this.root);

  static const SecurityService _security = SecurityService();

  /// 原子写的临时文件序号（见 [saveNote]）。
  static int _tmpSeq = 0;

  /// `<appDocuments>/Xiaoji`
  final Directory root;

  static const String _rootName = 'Xiaoji';

  static Future<NoteStore> create() async {
    final documents = await getApplicationDocumentsDirectory();
    return openAt(Directory(p.join(documents.path, _rootName)));
  }

  /// 测试或迁移时可以指定目录。
  static Future<NoteStore> openAt(Directory directory) async {
    final store = NoteStore._(directory);
    await store.ensureDirectories();
    await store._migrateLegacyTrash();
    return store;
  }

  Directory get notesDir => Directory(p.join(root.path, 'notes'));

  Directory get assetsDir => Directory(p.join(root.path, 'assets'));

  Directory get trashDir => Directory(p.join(root.path, 'trash'));

  /// 历史版本目录：`versions/<noteId>/<时间戳>.md`。
  ///
  /// 存的是「保存前的原始文件字节」（锁定笔记即密文），所以不需要解密，
  /// 也不会产生明文副本；目录本身排除在备份/导出之外。
  Directory get versionsDir => Directory(p.join(root.path, 'versions'));

  Directory get backupsDir => Directory(p.join(root.path, 'backups'));

  File get settingsFile => File(p.join(root.path, 'settings.json'));

  /// 搜索索引（派生数据，不进备份/导出，删掉自动重建）。
  String get searchIndexPath =>
      p.join(root.path, 'index', 'search-v${SearchIndex.schemaVersion}.db');

  Future<void> ensureDirectories() async {
    await root.create(recursive: true);
    await notesDir.create(recursive: true);
    await assetsDir.create(recursive: true);
    await trashDir.create(recursive: true);
    await versionsDir.create(recursive: true);
    await backupsDir.create(recursive: true);
  }

  /// 笔记的落盘路径。按年月分目录，避免单目录塞几千个文件后 iOS 上变慢。
  String pathFor(Note note) {
    final created = note.created.toLocal();
    final month = created.month.toString().padLeft(2, '0');
    return p.join(notesDir.path, '${created.year}', month, '${note.id}.md');
  }

  /// 把 markdown 里的相对路径（`assets/<id>/1.jpg`）还原成绝对路径。
  String absoluteAssetPath(String relativePath) {
    if (p.isAbsolute(relativePath)) {
      return relativePath;
    }
    return p.join(root.path, relativePath);
  }

  Directory assetDirectoryOf(String noteId) =>
      Directory(p.join(assetsDir.path, noteId));

  /// 读取全部笔记。
  ///
  /// 单条解析失败就跳过：用户可能在「文件」App 里手改过某个 .md，
  /// 一条坏文件绝不能导致整个 app 白屏。
  Future<List<Note>> loadNotes() async {
    final result = <Note>[];
    if (!await notesDir.exists()) {
      return result;
    }
    await for (final entity
        in notesDir.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      if (!entity.path.toLowerCase().endsWith('.md')) {
        continue;
      }
      try {
        final raw = await entity.readAsString();
        final note = Note.decode(
          raw,
          fallbackId: p.basenameWithoutExtension(entity.path),
        );
        if (note != null) {
          // 锁定笔记：正文是密文，内存里不能保留（否则列表摘要/搜索
          // 会把 base64 当正文显示）。打开时再按需解密。
          result.add(
            note.locked && note.body.startsWith(Note.lockEnvelopePrefix)
                ? note.copyWith(body: '')
                : note,
          );
        }
      } catch (_) {
        // 忽略坏文件，继续读下一条。
      }
    }
    return result;
  }

  /// 写入一条笔记。
  ///
  /// 先写 `.tmp` 再 rename：写大图片/长文本时进程被杀，rename 是原子操作，
  /// 所以用户要么看到旧内容，要么看到新内容，绝不会看到半截文件。
  Future<void> saveNote(Note note, {bool keepHistory = true}) async {
    // 锁定笔记：正文在落盘前加密成信封。
    // 恢复备份时 body 已经是信封（以 XIAOJI-LOCK-1: 开头），不能再加一层。
    Note toWrite = note;
    if (note.locked && !note.body.startsWith(Note.lockEnvelopePrefix)) {
      if (note.body.isEmpty) {
        // 锁定笔记在内存里正文是空串（见 [loadNotes]）：改置顶/标签时
        // 不能拿空正文去覆盖磁盘上已有的密文，否则正文就丢了。
        final existing = await readLockedEnvelope(note.id);
        if (existing != null) {
          toWrite = note.copyWith(body: '${Note.lockEnvelopePrefix}$existing');
        } else {
          final sealed = await _security.sealText('');
          toWrite = note.copyWith(body: '${Note.lockEnvelopePrefix}$sealed');
        }
      } else {
        final sealed = await _security.sealText(note.body);
        toWrite = note.copyWith(
          body: '${Note.lockEnvelopePrefix}$sealed',
        );
      }
    }
    final target = File(pathFor(toWrite));
    await target.parent.create(recursive: true);
    // 覆盖前给旧内容留一版：版本是「保存前的原始字节」，锁定笔记即密文。
    if (keepHistory && await target.exists()) {
      try {
        await _snapshotBeforeOverwrite(
          noteId: toWrite.id,
          target: target,
          nextBody: toWrite.body,
        );
      } catch (error) {
        // 历史版本只是保险，写失败绝不能拦住正文保存。
        debugPrint('写入历史版本失败（不影响保存）：$error');
      }
    }
    // 临时文件名带序号：同一条笔记可能有两笔保存同时在飞（例如防抖保存
    // 和「锁定笔记」的强制保存），共用一个 `.tmp` 会互相截断内容。
    // 仍然以 `.tmp` 结尾，备份/恢复/导出都按这个后缀跳过临时文件。
    final tmp = File('${target.path}.${_tmpSeq++}.tmp');
    await tmp.writeAsString(toWrite.encode(), flush: true);
    await tmp.rename(target.path);
  }

  /// 是否存在该笔记文件（用于判断恢复/覆盖场景）。
  Future<bool> noteFileExists(Note note) => File(pathFor(note)).exists();

  // ---------------------------------------------------------------------------
  // 历史版本
  // ---------------------------------------------------------------------------

  /// 同一篇笔记两次快照的最小间隔；当天第一版不受此限制。
  static const Duration _versionThrottle = Duration(minutes: 10);
  static const int _versionKeepRecent = 20;
  static const int _versionKeepDays = 30;

  final RegExp _versionName = RegExp(
    r'^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-(\d{3})$',
  );

  Directory versionDirectoryOf(String noteId) =>
      Directory(p.join(versionsDir.path, noteId));

  /// 覆盖前把旧文件留一版。
  ///
  /// 规则：
  ///  - 正文（锁定笔记是密文）没变 → 不留；
  ///  - 与最新一版内容相同 → 不留（去重）；
  ///  - 距最新一版不足 10 分钟且当天已有版本 → 不留（节流）；
  ///  - 当天还没有版本 → 强制留一版（每天至少一个还原点）。
  Future<void> _snapshotBeforeOverwrite({
    required String noteId,
    required File target,
    required String nextBody,
    bool force = false,
  }) async {
    final String oldRaw = await target.readAsString();
    final Note? oldNote = Note.decode(oldRaw, fallbackId: noteId);
    if (!force && oldNote != null && oldNote.body == nextBody) {
      return;
    }

    final Directory directory = versionDirectoryOf(noteId);
    await directory.create(recursive: true);
    final List<NoteVersion> versions = await _listVersionFiles(noteId);
    final DateTime now = DateTime.now();
    if (versions.isNotEmpty && !force) {
      final NoteVersion newest = versions.first;
      if (await newest.file.readAsString() == oldRaw) {
        return;
      }
      if (isSameDay(newest.time, now) &&
          now.difference(newest.time) < _versionThrottle) {
        return;
      }
    }

    final File file = File(p.join(directory.path, '${_versionStamp(now)}.md'));
    final File tmp = File('${file.path}.${_tmpSeq++}.tmp');
    await tmp.writeAsString(oldRaw, flush: true);
    await tmp.rename(file.path);
    await _pruneVersions(noteId);
  }

  String _versionStamp(DateTime time) {
    final t = time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}-${three(t.millisecond)}';
  }

  DateTime? _parseVersionTime(String name) {
    final RegExpMatch? match = _versionName.firstMatch(name);
    if (match == null) {
      return null;
    }
    int part(int index) => int.tryParse(match.group(index) ?? '') ?? 0;
    final DateTime parsed = DateTime(
      part(1),
      part(2),
      part(3),
      part(4),
      part(5),
      part(6),
      part(7),
    );
    return parsed;
  }

  Future<List<NoteVersion>> _listVersionFiles(String noteId) async {
    final Directory directory = versionDirectoryOf(noteId);
    if (!await directory.exists()) {
      return const <NoteVersion>[];
    }
    final List<NoteVersion> versions = <NoteVersion>[];
    await for (final FileSystemEntity entity in directory.list()) {
      if (entity is! File ||
          !entity.path.toLowerCase().endsWith('.md') ||
          entity.path.endsWith('.tmp')) {
        continue;
      }
      final String name = p.basenameWithoutExtension(entity.path);
      final DateTime? time = _parseVersionTime(name);
      if (time == null) {
        continue;
      }
      final int size = await entity.length();
      versions.add(NoteVersion(file: entity, time: time, size: size));
    }
    versions.sort(
      (NoteVersion a, NoteVersion b) => b.time.compareTo(a.time),
    );
    return versions;
  }

  /// 列出某篇笔记的历史版本（新到旧）。
  Future<List<NoteVersion>> listVersions(String noteId) =>
      _listVersionFiles(noteId);

  /// 读取某个版本的原始文件内容（含 frontmatter）。
  Future<String> readVersion(NoteVersion version) =>
      version.file.readAsString();

  /// 恢复到某个版本。
  ///
  /// 恢复前强制把当前内容留一版（可撤销）；锁定笔记会继续保持锁定，
  /// 明文版本会被重新加密后落盘。
  Future<Note?> restoreVersion(Note current, NoteVersion version) async {
    final String raw = await version.file.readAsString();
    final Note? restored = Note.decode(raw, fallbackId: current.id);
    if (restored == null) {
      return null;
    }
    final File target = File(pathFor(current));
    if (await target.exists()) {
      final Note? old = Note.decode(
        await target.readAsString(),
        fallbackId: current.id,
      );
      await _snapshotBeforeOverwrite(
        noteId: current.id,
        target: target,
        nextBody: old?.body ?? '',
        force: true,
      );
    }
    final Note toWrite = restored.copyWith(
      id: current.id,
      // 当前是锁定笔记、或这一版本身是密文：恢复后继续保持锁定。
      locked: current.locked || restored.locked,
      body: restored.body,
    );
    await saveNote(toWrite, keepHistory: false);
    if (toWrite.locked) {
      try {
        // 编辑器需要明文；密文版本在这里解密，明文版本直接返回。
        final String plain = await readNoteBody(toWrite);
        return toWrite.copyWith(body: plain);
      } catch (_) {
        // 解密失败（密钥失效）：保持原样，界面只展示「已锁定」。
      }
    }
    return toWrite;
  }

  /// 保留最近 20 版 + 最近 30 天每天最新一版，其余删除。
  Future<void> _pruneVersions(String noteId) async {
    final List<NoteVersion> versions = await _listVersionFiles(noteId);
    if (versions.isEmpty) {
      return;
    }
    final Set<String> keep = <String>{};
    for (var i = 0; i < versions.length && i < _versionKeepRecent; i++) {
      keep.add(versions[i].file.path);
    }
    final DateTime now = DateTime.now();
    final Set<String> days = <String>{};
    for (final NoteVersion version in versions) {
      if (now.difference(version.time).inDays > _versionKeepDays) {
        continue;
      }
      final String day =
          '${version.time.year}-${version.time.month}-${version.time.day}';
      if (days.add(day)) {
        keep.add(version.file.path);
      }
    }
    for (final NoteVersion version in versions) {
      if (keep.contains(version.file.path)) {
        continue;
      }
      try {
        await version.file.delete();
      } catch (_) {
        // 单个版本删不掉不影响其它文件。
      }
    }
  }

  /// 删除笔记：**整体**移进 `trash/<id>/`（正文 + 附件 + 元信息）。
  ///
  /// 之前的实现只留正文、把附件目录直接删掉 —— 删错了图就永远找不回。
  /// 现在三样一起进回收站，[restoreFromTrash] 能原样还原。
  Future<void> deleteNote(Note note) async {
    final directory = trashDirectoryOf(note.id);
    await directory.create(recursive: true);

    // 同一 id 之前删过（极端情况）：先挪走旧的，避免覆盖后无法还原。
    // `Directory.list()` 返回 Stream，用 Stream.isEmpty 判空。
    final bool hasExisting =
        !await directory.list(followLinks: false).isEmpty;
    if (hasExisting) {
      final stamp = DateTime.now().millisecondsSinceEpoch;
      await _moveDirectory(directory, Directory('${directory.path}-$stamp'));
      await directory.create(recursive: true);
    }

    final file = File(pathFor(note));
    if (await file.exists()) {
      await _moveFile(file, File(p.join(directory.path, 'note.md')));
    }
    final assets = assetDirectoryOf(note.id);
    if (await assets.exists()) {
      await _moveDirectory(assets, Directory(p.join(directory.path, 'assets')));
    }
    // 历史版本跟着笔记一起进回收站，避免留下孤儿目录。
    final versions = versionDirectoryOf(note.id);
    if (await versions.exists()) {
      await _moveDirectory(
        versions,
        Directory(p.join(directory.path, 'versions')),
      );
    }

    final meta = <String, Object?>{
      'id': note.id,
      'deletedAt': DateTime.now().toIso8601String(),
      'created': note.created.toIso8601String(),
      'updated': note.updated.toIso8601String(),
      'tags': note.tags,
      'pinned': note.pinned,
      'locked': note.locked,
    };
    await File(p.join(directory.path, 'meta.json'))
        .writeAsString(jsonEncode(meta), flush: true);
  }

  /// 回收站里某条笔记的目录。
  Directory trashDirectoryOf(String noteId) =>
      Directory(p.join(trashDir.path, noteId));

  /// 列出回收站条目（按删除时间倒序）。
  ///
  /// 兼容旧版遗留的 `trash/<id>.md` 平铺文件：读不到 meta 时用文件
  /// 修改时间兜底，界面提示「附件已丢失」。
  Future<List<TrashedNote>> listTrash() async {
    final result = <TrashedNote>[];
    if (!await trashDir.exists()) {
      return result;
    }
    try {
      await for (final entity in trashDir.list(followLinks: false)) {
      if (entity is Directory) {
        final metaFile = File(p.join(entity.path, 'meta.json'));
        final noteFile = File(p.join(entity.path, 'note.md'));
        if (!await noteFile.exists()) {
          continue;
        }
        String id = p.basename(entity.path);
        DateTime deletedAt = await noteFile.lastModified();
        List<String> tags = const <String>[];
        bool hasAssets =
            await Directory(p.join(entity.path, 'assets')).exists();
        String title = '';
        bool locked = false;
        try {
          final raw = await noteFile.readAsString();
          final note = Note.decode(
            raw,
            fallbackId: p.basenameWithoutExtension(noteFile.path),
          );
          if (note != null) {
            locked = note.locked;
            tags = note.tags;
            if (!locked) {
              title = _firstLine(note.body);
            }
          }
        } catch (_) {
          // 坏文件：仍列出来，恢复时再报错。
        }
        if (await metaFile.exists()) {
          try {
            final decoded = jsonDecode(await metaFile.readAsString());
            if (decoded is Map<String, dynamic>) {
              final rawId = decoded['id'];
              if (rawId is String && rawId.isNotEmpty) {
                id = rawId;
              }
              final rawDeleted = decoded['deletedAt'];
              final parsed =
                  rawDeleted is String ? DateTime.tryParse(rawDeleted) : null;
              if (parsed != null) {
                deletedAt = parsed;
              }
              final rawTags = decoded['tags'];
              if (rawTags is List) {
                tags = rawTags.whereType<String>().toList();
              }
            }
          } catch (_) {
            // meta 坏了不影响恢复正文，用默认值继续。
          }
        }
        result.add(TrashedNote(
          id: id,
          directory: entity,
          deletedAt: deletedAt,
          tags: tags,
          hasAssets: hasAssets,
          title: title,
          locked: locked,
        ));
      } else if (entity is File &&
          entity.path.toLowerCase().endsWith('.md')) {
        // 旧版遗留：只有正文，附件已丢失。
        String legacyTitle = '';
        try {
          final note = Note.decode(
            await entity.readAsString(),
            fallbackId: p.basenameWithoutExtension(entity.path),
          );
          legacyTitle = note == null ? '' : _firstLine(note.body);
        } catch (_) {
          // 坏文件不阻断列表。
        }
        result.add(TrashedNote(
          id: p.basenameWithoutExtension(entity.path),
          directory: entity,
          deletedAt: await entity.lastModified(),
          tags: const <String>[],
          hasAssets: false,
          legacyFile: true,
          title: legacyTitle,
        ));
      }
    }
    } catch (_) {
      // 目录在读取过程中被删（清理任务/外部操作）：返回已读到的部分。
      return result;
    }
    result.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return result;
  }

  /// 从回收站恢复：正文写回 notes/，附件搬回 assets/。
  ///
  /// 返回恢复后的 Note（解析失败返回 null，条目保持原样供人工处理）。
  Future<Note?> restoreFromTrash(TrashedNote trashed) async {
    final entity = trashed.directory;
    if (trashed.legacyFile) {
      final file = entity as File;
      final raw = await file.readAsString();
      final note = Note.decode(
        raw,
        fallbackId: p.basenameWithoutExtension(file.path),
      );
      if (note == null) {
        return null;
      }
      await saveNote(note, keepHistory: false);
      await file.delete();
      return note;
    }

    final directory = entity as Directory;
    final noteFile = File(p.join(directory.path, 'note.md'));
    if (!await noteFile.exists()) {
      return null;
    }
    final raw = await noteFile.readAsString();
    final note = Note.decode(raw, fallbackId: trashed.id);
    if (note == null) {
      return null;
    }
    await saveNote(note, keepHistory: false);
    final assets = Directory(p.join(directory.path, 'assets'));
    if (await assets.exists()) {
      final target = assetDirectoryOf(note.id);
      if (await target.exists()) {
        await target.delete(recursive: true);
      }
      await _moveDirectory(assets, target);
    }
    final versions = Directory(p.join(directory.path, 'versions'));
    if (await versions.exists()) {
      final target = versionDirectoryOf(note.id);
      if (await target.exists()) {
        await target.delete(recursive: true);
      }
      await _moveDirectory(versions, target);
    }
    await directory.delete(recursive: true);
    return note;
  }

  /// 按笔记 id 从回收站找回（删除后 SnackBar 撤销用）。
  Future<Note?> restoreTrashById(String noteId) async {
    final entries = await listTrash();
    for (final entry in entries) {
      if (entry.id != noteId) {
        continue;
      }
      return restoreFromTrash(entry);
    }
    return null;
  }

  /// 彻底删除一条回收站条目（正文与附件一起消失）。
  Future<void> purgeTrash(TrashedNote trashed) async {
    final entity = trashed.directory;
    if (await entity.exists()) {
      await entity.delete(recursive: true);
    }
  }

  /// 清空回收站。
  Future<void> purgeAllTrash() async {
    if (!await trashDir.exists()) {
      return;
    }
    await for (final entity in trashDir.list(followLinks: false)) {
      await entity.delete(recursive: true);
    }
  }

  /// 清理超过 [retention] 的回收站条目（默认 30 天）。
  ///
  /// 返回清理条数。启动时调用一次，避免回收站无限增长。
  Future<int> purgeExpiredTrash({
    Duration retention = const Duration(days: 30),
  }) async {
    final entries = await listTrash();
    final now = DateTime.now();
    var removed = 0;
    for (final entry in entries) {
      if (now.difference(entry.deletedAt) < retention) {
        continue;
      }
      try {
        await purgeTrash(entry);
        removed += 1;
      } catch (_) {
        // 条目正被其它流程删除：跳过即可。
      }
    }
    return removed;
  }

  /// 旧版 `trash/<id>.md` 平铺结构无需迁移到目录结构：
  /// [listTrash] 已兼容读取，恢复时直接写回 notes/ 即可。
  Future<void> _migrateLegacyTrash() async {
    // 预留钩子：未来若回收站结构再变，从这里做一次性迁移。
  }

  /// 打包时永远排除的目录：
  ///  - `backups/`：备份不该把旧备份再套一层（体积翻倍），而且锁定前的
  ///    旧备份里是明文，带出去等于绕过单篇锁定；
  ///  - `trash/`：已删除的笔记不该出现在导出/备份里（既是隐私面，也会
  ///    在「从备份恢复」时把删掉的笔记重新复活成正常笔记）；
  ///  - `tmp/`：临时文件，原生 zip 已跳过。
  static const List<String> _alwaysExcluded = <String>[
    'backups',
    'trash',
    'tmp',
    // 历史版本是本地保险，且锁定笔记的版本可能是密文/旧明文：
    // 不进备份也不进导出，避免体积翻倍与隐私面扩大。
    'versions',
    // 搜索索引是派生数据，且里面是正文分词后的明文：既不该进备份，
    // 也不该被导出。删掉后下次启动会自动重建。
    'index',
  ];

  /// 恢复时同样跳过这些目录（旧导出包里可能带着它们）。
  ///
  /// `export-*` 是旧版本「导出到私有目录」留下的明文副本，里面是同一批
  /// 笔记的旧快照；恢复时不该被当成独立笔记再写一遍。
  static bool _isExcludedArchivePath(String path) {
    final String first = path.split('/').first;
    if (first.startsWith('export-')) {
      return true;
    }
    for (final dir in _alwaysExcluded) {
      if (path == dir || path.startsWith('$dir/')) {
        return true;
      }
    }
    return false;
  }

  /// 生成备份文件（应用私有 `backups/`）。
  ///
  /// **包含锁定笔记的密文**：备份主要用于同机误删/误覆盖恢复，此时
  /// 设备 Keystore 密钥还在，密文能正常解开。之前把锁定笔记排除在备份外，
  /// 导致清空回收站或超过 30 天后锁定笔记永久丢失 —— 这是不应有的缺口。
  /// 锁定笔记的**明文导出**仍然默认排除（见 [buildExportZipToFile]），
  /// 因为导出面向换机/分享，密钥离开本设备就失效了。
  Future<File> createBackupFile({required String name}) async {
    await ensureDirectories();
    final file = await _uniqueBackupFile(name);
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.parent.create(recursive: true);
    try {
      await zipNotesToFile(
        sourceRoot: root.path,
        targetPath: tmp.path,
        excludes: <String>[
          ..._alwaysExcluded,
          // 旧版本留下的明文导出目录：不该被备份打包带出去。
          ...await _legacyExportDirs(),
        ],
      );
      await tmp.rename(file.path);
    } on MissingPluginException {
      // 内存版只读磁盘文件，锁定笔记写进去的仍是密文。
      final bytes = await buildExportZip();
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    } catch (error) {
      // 压缩失败不能留下半截 `.tmp`（虽然列表过滤 .zip，但会白白占磁盘）。
      try {
        if (await tmp.exists()) {
          await tmp.delete();
        }
      } catch (_) {
        // 删不掉也不影响把原始错误抛给上层。
      }
      rethrow;
    }
    // 手动备份不设上限会一直堆，磁盘写满后连笔记都存不下。
    // 只保留最近 5 份（auto-* 由 pruneAutoBackups 单独管，恢复前快照不动）。
    if (p.basename(file.path).startsWith('manual-')) {
      await pruneManualBackups(keep: 5);
    }
    return file;
  }

  /// 导出的临时 zip（写进 Xiaoji/tmp，保存到用户位置后由调用方删除）。
  Future<File> createTempExportFile(String name) async {
    final directory = Directory(p.join(root.path, 'tmp'));
    await directory.create(recursive: true);
    return File(p.join(directory.path, name));
  }

  /// 恢复前快照：恢复是覆盖语义，先留一份可回滚的当前数据。
  Future<File> createPreRestoreSnapshot() async {
    final stamp = formatExportStamp(DateTime.now());
    final file = await createBackupFile(name: 'pre-restore-$stamp.zip');
    // 快照也保留最近 3 份：每次恢复都会产生一份，不清理同样会堆积。
    await _pruneByPrefix('pre-restore-', keep: 3);
    return file;
  }

  /// 距上次备份超过 24 小时时生成一份自动备份，保留最近 [keep] 份。
  ///
  /// 不再按「自然日」判断：手机 App 可能几天不冷启动，按日期会导致
  /// 连续多天没有备份。用「距最近一次备份 ≥24h」作为节奏，且只在
  /// 启动/回到前台时调用（见 [NoteRepository.runMaintenance]）。
  ///
  /// 返回新建的备份文件；24 小时内已有备份则返回 null。
  /// 失败时不再吞异常，由上层记录状态（设置页显示「上次备份失败」）。
  Future<File?> ensureAutoBackup({int keep = 3}) async {
    final DateTime? last = await lastBackupTime();
    if (last != null &&
        DateTime.now().difference(last) < const Duration(hours: 24)) {
      return null;
    }
    final String stamp = formatExportStamp(DateTime.now());
    final File created = await createBackupFile(name: 'auto-$stamp.zip');
    await pruneAutoBackups(keep: keep);
    return created;
  }

  /// 把导出包写进用户授权的 SAF 目录（外置备份）。
  ///
  /// 解决「应用私有目录 + 私有备份同归于尽」的问题：手机丢失/刷机时，
  /// 用户选的文件夹（SD 卡、其他 App 目录、网盘同步目录）里还有一份。
  ///
  /// 语义与「导出全部」的默认一致：**不含锁定笔记的明文**（密文换机也解不开），
  /// 也不含回收站与旧备份。
  ///
  /// [lastAt] 是上次成功时间：不足 24 小时直接跳过（[force] 为 true 时忽略），
  /// 避免每次回前台都重新打包。返回本次备份时间；跳过时返回 null。
  Future<DateTime?> ensureExternalBackup({
    required String treeUri,
    DateTime? lastAt,
    int keep = 3,
    bool force = false,
  }) async {
    final DateTime now = DateTime.now();
    if (!force &&
        lastAt != null &&
        now.difference(lastAt) < const Duration(hours: 24)) {
      return null;
    }
    // 文件名带秒：同一分钟内连点两次「立即导出」也不会撞名。
    final String stamp =
        '${formatExportStamp(now)}-${now.second.toString().padLeft(2, '0')}';
    final String name = 'xiaoji-$stamp.zip';
    final File temp = await createTempExportFile('external-$stamp.zip');
    try {
      await buildExportZipToFile(temp.path);
      await writeFileToTree(
        treeUri: treeUri,
        sourcePath: temp.path,
        fileName: name,
        keepPrefix: 'xiaoji-',
        keep: keep,
      );
      return now;
    } finally {
      // 临时 zip 是完整数据副本：写完必须删，失败也不能留。
      try {
        if (await temp.exists()) {
          await temp.delete();
        }
      } catch (_) {
        // 删不掉由 cleanTempDir 在下次启动时兜底。
      }
    }
  }

  /// 只保留最近 [keep] 份 `auto-*.zip`（`pre-restore-*` 不动）。
  Future<void> pruneAutoBackups({int keep = 3}) =>
      _pruneByPrefix('auto-', keep: keep);

  /// 只保留最近 [keep] 份手动备份，避免无限堆积占满磁盘。
  Future<void> pruneManualBackups({int keep = 5}) =>
      _pruneByPrefix('manual-', keep: keep);

  /// 备份文件名去重：同一分钟内点两次「立即备份」不能互相覆盖。
  Future<File> _uniqueBackupFile(String name) async {
    final base = p.basenameWithoutExtension(name);
    final extension = p.extension(name);
    var candidate = File(p.join(backupsDir.path, name));
    var index = 2;
    while (await candidate.exists()) {
      candidate = File(p.join(backupsDir.path, '$base-$index$extension'));
      index += 1;
    }
    return candidate;
  }

  /// 旧版本 `exportAll()` 留在根目录的 `export-*` 明文副本。
  ///
  /// 该方法已删除，但历史设备上可能还有残留目录；备份/导出时一并排除，
  /// 否则旧明文会被重复打包带走。
  Future<List<String>> _legacyExportDirs() async {
    final dirs = <String>[];
    try {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is Directory &&
            p.basename(entity.path).startsWith('export-')) {
          dirs.add(p.basename(entity.path));
        }
      }
    } catch (_) {
      // 目录读不到就等于没有残留，不影响主流程。
    }
    return dirs;
  }

  /// 按文件名前缀清理备份，只保留最新 [keep] 份。
  Future<void> _pruneByPrefix(String prefix, {required int keep}) async {
    if (!await backupsDir.exists()) {
      return;
    }
    final files = <File>[];
    await for (final entity in backupsDir.list(followLinks: false)) {
      if (entity is File &&
          entity.path.toLowerCase().endsWith('.zip') &&
          p.basename(entity.path).startsWith(prefix)) {
        files.add(entity);
      }
    }
    files.sort((a, b) => b.path.compareTo(a.path));
    for (var i = keep; i < files.length; i++) {
      await files[i].delete();
    }
  }

  /// 列出应用私有目录里的备份（按修改时间倒序，最多 [limit] 份）。
  ///
  /// 「从备份恢复」要能选到这些文件：私有目录在系统文件管理器里看不到，
  /// 只靠「选择文件」等于永远恢复不了自动/立即备份。
  Future<List<BackupEntry>> listBackups({int limit = 6}) async {
    if (!await backupsDir.exists()) {
      return const <BackupEntry>[];
    }
    final entries = <BackupEntry>[];
    await for (final entity in backupsDir.list(followLinks: false)) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.zip')) {
        continue;
      }
      final DateTime time = await entity.lastModified();
      entries.add(BackupEntry(
        file: entity,
        time: time,
        kind: BackupKind.ofName(p.basename(entity.path)),
      ));
    }
    entries.sort((BackupEntry a, BackupEntry b) => b.time.compareTo(a.time));
    return entries.take(limit).toList();
  }

  /// 清理导出临时目录里超过 1 小时的残留文件。
  ///
  /// 正常情况下导出结束会自己删；进程恰好在写盘瞬间被杀时才会留下
  /// 明文/zip 副本。启动时兜底清一遍，1 小时门槛避免误删正在用的文件。
  Future<void> cleanTempDir() async {
    final directory = Directory(p.join(root.path, 'tmp'));
    if (!await directory.exists()) {
      return;
    }
    final DateTime now = DateTime.now();
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) {
          continue;
        }
        try {
          final DateTime modified = await entity.lastModified();
          if (now.difference(modified) >= const Duration(hours: 1)) {
            await entity.delete(recursive: true);
          }
        } catch (_) {
          // 单个残留文件删不掉不影响其它文件。
        }
      }
    } catch (_) {
      // 目录被并发删除等异常：忽略，下次启动再清。
    }
  }

  /// 最近一次备份时间（auto / pre-restore 都算），用于设置页展示。
  Future<DateTime?> lastBackupTime() async {
    if (!await backupsDir.exists()) {
      return null;
    }
    DateTime? latest;
    await for (final entity in backupsDir.list(followLinks: false)) {
      if (entity is! File || !entity.path.toLowerCase().endsWith('.zip')) {
        continue;
      }
      final modified = await entity.lastModified();
      if (latest == null || modified.isAfter(latest)) {
        latest = modified;
      }
    }
    return latest;
  }

  /// 移动文件，跨设备 rename 失败时退化为复制 + 删除。
  Future<void> _moveFile(File source, File target) async {
    await target.parent.create(recursive: true);
    try {
      await source.rename(target.path);
    } on FileSystemException {
      await source.copy(target.path);
      await source.delete();
    }
  }

  /// 移动目录，跨设备时退化为递归复制 + 删除。
  Future<void> _moveDirectory(Directory source, Directory target) async {
    await target.parent.create(recursive: true);
    try {
      await source.rename(target.path);
    } on FileSystemException {
      await _copyTree(source, target);
      await source.delete(recursive: true);
    }
  }

  /// 把外部文件拷进笔记自己的附件目录，返回写进 markdown 的相对路径。
  ///
  /// 序号用「当前最大序号 + 1」而不是时间戳：`1.jpg` `2.jpg` 更可读，
  /// 也方便用户在「文件」App 里手动收拾。
  Future<String> importAttachment({
    required String noteId,
    required String sourcePath,
  }) async {
    final directory = assetDirectoryOf(noteId);
    await directory.create(recursive: true);

    var maxIndex = 0;
    await for (final entity in directory.list()) {
      if (entity is! File) {
        continue;
      }
      final match = RegExp(r'^(\d+)\.').firstMatch(p.basename(entity.path));
      if (match == null) {
        continue;
      }
      final index = int.tryParse(match.group(1)!);
      if (index != null && index > maxIndex) {
        maxIndex = index;
      }
    }

    var extension = p.extension(sourcePath).toLowerCase();
    if (extension.isEmpty) {
      extension = '.bin';
    }
    final fileName = '${maxIndex + 1}$extension';
    await File(sourcePath).copy(p.join(directory.path, fileName));
    return 'assets/$noteId/$fileName';
  }

  /// 从导出 zip 恢复笔记与附件（导出结构对称：.md 平铺根目录、
  /// 附件在 assets/ 下）。
  ///
  /// 同 id 笔记直接覆盖（恢复语义就是回到导出时的状态）；返回
  /// (恢复篇数, 跳过篇数)——跳过 = md 无法解析（坏了的文件不中断整体）。
  /// zip 内路径做了 `..` 防护，防恶意压缩包越目录写文件。
  Future<(int, int)> restoreFromZip(Uint8List bytes) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    var restored = 0;
    var skipped = 0;
    for (final entry in archive.files) {
      if (!entry.isFile) {
        continue;
      }
      final name = entry.name.replaceAll('\\', '/');
      if (name.contains('..')) {
        continue; // 路径越界防护
      }
      // 旧版导出包里可能带 trash/、backups/（嵌套备份）、tmp/：
      // 里面的 .md 若被当普通笔记恢复，已删除内容就「复活」了。
      if (_isExcludedArchivePath(name)) {
        continue;
      }
      if (name.toLowerCase().endsWith('.md')) {
        final raw = utf8.decode(entry.content as List<int>);
        final note = Note.decode(
          raw,
          fallbackId: p.basenameWithoutExtension(name),
        );
        if (note == null) {
          skipped += 1;
          continue;
        }
        await saveNote(note, keepHistory: false);
        restored += 1;
      } else if (name.startsWith('assets/')) {
        final relative = name.substring('assets/'.length);
        if (relative.isEmpty) {
          continue;
        }
        final target = File(p.join(assetsDir.path, relative));
        await target.parent.create(recursive: true);
        await target.writeAsBytes(entry.content as List<int>);
      }
    }
    return (restored, skipped);
  }

  /// 从**文件路径**恢复（原生流式解压，避免把整个 zip 读进内存）。
  Future<(int, int)> restoreFromZipFile(String zipPath) async {
    final temp = await Directory.systemTemp.createTemp('xiaoji_restore_');
    try {
      await unzipTo(zipPath: zipPath, destDir: temp.path);
      return await _restoreFromDirectory(temp);
    } finally {
      try {
        await temp.delete(recursive: true);
      } catch (_) {
        // 临时目录清理失败不影响恢复结果。
      }
    }
  }

  /// 把解压目录按「.md 平铺 + assets/」结构合并进当前 store。
  Future<(int, int)> _restoreFromDirectory(Directory directory) async {
    var restored = 0;
    var skipped = 0;
    await for (final entity
        in directory.list(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final name =
          p.relative(entity.path, from: directory.path).replaceAll('\\', '/');
      if (name.contains('..') ||
          name.endsWith('.tmp') ||
          _isExcludedArchivePath(name)) {
        continue;
      }
      if (name.startsWith('assets/')) {
        final relative = name.substring('assets/'.length);
        if (relative.isEmpty) {
          continue;
        }
        final target = File(p.join(assetsDir.path, relative));
        await target.parent.create(recursive: true);
        await entity.copy(target.path);
      } else if (name.toLowerCase().endsWith('.md')) {
        try {
          final raw = await entity.readAsString();
          final note = Note.decode(
            raw,
            fallbackId: p.basenameWithoutExtension(name),
          );
          if (note == null) {
            skipped += 1;
          } else {
            await saveNote(note, keepHistory: false);
            restored += 1;
          }
        } catch (_) {
          skipped += 1;
        }
      }
    }
    return (restored, skipped);
  }

  /// 生成导出 zip 到指定路径（原生流式压缩）。
  ///
  /// [includeLocked] 为 false（默认）时排除锁定笔记的正文和附件。
  /// 为 true 时先把锁定正文解密写成临时明文文件，再在 zip 里替换掉密文
  /// 条目 —— 调用方必须先完成身份验证。单条解密失败时保持原密文条目，
  /// 不让一条坏数据拖垮整次导出。
  ///
  /// 导出给用户的包里不写真实 `settings.json`：里面有应用锁 PIN 的
  /// PBKDF2 哈希和盐，6 位数字 PIN 离开设备后可以离线枚举。这里写一份
  /// 只含主题/密度的脱敏版本。
  Future<File> buildExportZipToFile(
    String targetPath, {
    bool includeLocked = false,
  }) async {
    final file = File(targetPath);
    await file.parent.create(recursive: true);
    final excludes = <String>[];
    final overrides = <String, String>{};
    final tempFiles = <File>[];
    try {
      for (final note in await loadNotes()) {
        if (!note.locked) {
          continue;
        }
        final relative = p.relative(pathFor(note), from: root.path);
        if (!includeLocked) {
          excludes.add(relative);
          excludes.add('assets/${note.id}');
          continue;
        }
        try {
          final plain = await readNoteBody(note);
          final tmp = await createTempExportFile('plain-${note.id}.md');
          await tmp.writeAsString(
            note.copyWith(body: plain, locked: false).encode(),
            flush: true,
          );
          overrides[relative] = tmp.path;
          tempFiles.add(tmp);
        } catch (_) {
          // 密钥失效/文件损坏：这条保持密文原样导出，其余照常。
        }
      }
      final settingsOverride = await _writeRedactedSettings(tempFiles);
      if (settingsOverride != null) {
        overrides['settings.json'] = settingsOverride;
      }
      await zipNotesToFile(
        sourceRoot: root.path,
        targetPath: file.path,
        excludes: <String>[
          ..._alwaysExcluded,
          ...await _legacyExportDirs(),
          ...excludes,
        ],
        overrides: overrides,
      );
      return file;
    } finally {
      for (final tmp in tempFiles) {
        try {
          if (await tmp.exists()) {
            await tmp.delete();
          }
        } catch (_) {
          // 临时明文/配置删不掉也不影响导出结果。
        }
      }
    }
  }

  /// 生成脱敏的 `settings.json` 临时文件（只保留主题、密度、截屏开关）。
  Future<String?> _writeRedactedSettings(List<File> tempFiles) async {
    try {
      final settings = await loadSettings();
      final tmp = await createTempExportFile('export-settings.json');
      await tmp.writeAsString(
        jsonEncode(<String, Object?>{
          'theme': settings.theme.wireValue,
          'density': settings.density.wireValue,
          'secureScreen': settings.secureScreen,
        }),
        flush: true,
      );
      tempFiles.add(tmp);
      return tmp.path;
    } catch (_) {
      // 读不到设置就跳过覆盖，导出的包里不带 settings.json 也无妨。
      return null;
    }
  }

  /// 生成包含全部笔记与附件的 zip（在后台 isolate 执行）。
  ///
  /// 结构：.md 平铺在根目录、附件在 `assets/<noteId>/`，
  /// 解压后正文里的相对引用依然能打开。
  /// 这是导出的主通道 —— app 私有目录用户拿不走，必须经系统保存对话框
  /// 交到用户选的位置。
  ///
  /// 为什么要 compute：zip 要读全部笔记和附件再压缩，笔记多或带图时
  /// 主线程做这些会卡 UI（用户实测「导出时卡一下」就是这个）。
  /// isolate 里可以自由用 dart:io，直接传目录路径即可。
  Future<Uint8List> buildExportZip({
    Set<String> excludeNoteIds = const <String>{},
  }) {
    return compute(
      _buildExportZipSync,
      (notesDir.path, assetsDir.path, excludeNoteIds),
    );
  }

  /// 必须是顶层/静态函数才能进 isolate。
  static Future<Uint8List> _buildExportZipSync(
    (String, String, Set<String>) dirs,
  ) async {
    final (notesPath, assetsPath, excludeIds) = dirs;
    final archive = Archive();
    final notesDir = Directory(notesPath);
    if (await notesDir.exists()) {
      await for (final entity
          in notesDir.list(recursive: true, followLinks: false)) {
        if (entity is! File) {
          continue;
        }
        if (!entity.path.toLowerCase().endsWith('.md')) {
          continue;
        }
        if (excludeIds.contains(p.basenameWithoutExtension(entity.path))) {
          continue;
        }
        final bytes = await entity.readAsBytes();
        archive.addFile(
          ArchiveFile(p.basename(entity.path), bytes.length, bytes),
        );
      }
    }
    final assetsDir = Directory(assetsPath);
    if (await assetsDir.exists()) {
      await for (final entity
          in assetsDir.list(recursive: true, followLinks: false)) {
        if (entity is! File) {
          continue;
        }
        if (entity.path.endsWith('.tmp')) {
          continue;
        }
        final rel = p.relative(entity.path, from: assetsDir.path);
        // 附件按 `<noteId>/...` 存放：锁定笔记的整个附件目录一起排除。
        if (excludeIds.contains(rel.split(Platform.pathSeparator).first) ||
            excludeIds.contains(rel.split('/').first)) {
          continue;
        }
        final bytes = await entity.readAsBytes();
        archive.addFile(ArchiveFile('assets/$rel', bytes.length, bytes));
      }
    }
    final encoded = ZipEncoder().encode(archive);
    return Uint8List.fromList(encoded ?? <int>[]);
  }

  /// 取正文第一行做回收站标题（去掉标题符号/列表符号，截断到 60 字）。
  static String _firstLine(String body) {
    for (final rawLine in body.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        continue;
      }
      final cleaned = line
          .replaceFirst(RegExp(r'^#{1,6}\s*'), '')
          .replaceFirst(RegExp(r'^[-*+]\s+'), '');
      return cleaned.length > 60 ? '${cleaned.substring(0, 60)}…' : cleaned;
    }
    return '';
  }

  Future<void> _copyTree(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        await _copyTree(entity, Directory(p.join(destination.path, name)));
      } else if (entity is File) {
        if (entity.path.endsWith('.tmp')) {
          continue;
        }
        await entity.copy(p.join(destination.path, name));
      }
    }
  }

  Future<NoteSettings> loadSettings() async {
    try {
      if (!await settingsFile.exists()) {
        return const NoteSettings();
      }
      final raw = await settingsFile.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const NoteSettings();
      }
      return NoteSettings.fromJson(decoded);
    } catch (_) {
      // 配置文件坏掉不该拦住用户看笔记。
      return const NoteSettings();
    }
  }

  Future<void> saveSettings(NoteSettings settings) async {
    final tmp = File('${settingsFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(settings.toJson()), flush: true);
    await tmp.rename(settingsFile.path);
  }

  /// 读取一条笔记的明文正文（锁定笔记会先解密）。
  ///
  /// 调用方必须先完成身份验证；解密失败抛异常，由界面提示。
  Future<String> readNoteBody(Note note) async {
    if (!note.locked) {
      return note.body;
    }
    final envelope = await readLockedEnvelope(note.id);
    if (envelope == null) {
      // 历史数据：标记了 locked 但正文尚未加密，按明文返回。
      return note.body;
    }
    return _security.openText(envelope);
  }

  /// 读取锁定笔记的密文正文（`XIAOJI-LOCK-1:` 之后的部分）。
  ///
  /// 内存里的 Note.body 对锁定笔记是空串（见 [loadNotes]），
  /// 真正要解密时再按 id 回磁盘取密文，避免列表/搜索阶段碰明文。
  Future<String?> readLockedEnvelope(String noteId) async {
    for (final note in await _locateNoteFiles(noteId)) {
      final raw = await note.readAsString();
      final decoded = Note.decode(
        raw,
        fallbackId: p.basenameWithoutExtension(note.path),
      );
      if (decoded == null || !decoded.locked) {
        continue;
      }
      if (decoded.body.startsWith(Note.lockEnvelopePrefix)) {
        return decoded.body.substring(Note.lockEnvelopePrefix.length);
      }
    }
    return null;
  }

  /// 按 id 找到笔记文件（按年月分目录，需要扫一遍）。
  Future<List<File>> _locateNoteFiles(String noteId) async {
    final result = <File>[];
    if (!await notesDir.exists()) {
      return result;
    }
    await for (final entity
        in notesDir.list(recursive: true, followLinks: false)) {
      if (entity is File &&
          p.basenameWithoutExtension(entity.path) == noteId &&
          entity.path.toLowerCase().endsWith('.md')) {
        result.add(entity);
      }
    }
    return result;
  }

  /// 写回锁定笔记的密文正文（保持 frontmatter 中的 locked: true）。
  Future<void> saveLockedEnvelope(Note note, String envelope) async {
    await saveNote(note.copyWith(
      locked: true,
      body: '${Note.lockEnvelopePrefix}$envelope',
    ));
  }
}

/// 一个历史版本（磁盘上的一个快照文件）。
class NoteVersion {
  const NoteVersion({
    required this.file,
    required this.time,
    required this.size,
  });

  final File file;
  final DateTime time;
  final int size;

  String get name => p.basename(file.path);
}

/// 回收站里的一条笔记。
class TrashedNote {
  const TrashedNote({
    required this.id,
    required this.directory,
    required this.deletedAt,
    this.tags = const <String>[],
    this.hasAssets = false,
    this.legacyFile = false,
    this.title = '',
    this.locked = false,
  });

  final String id;

  /// 目录（新结构）或单个 .md 文件（旧结构）。
  final FileSystemEntity directory;
  final DateTime deletedAt;
  final List<String> tags;
  final bool hasAssets;

  /// 首行摘要（锁定笔记为空，界面显示「已锁定」）。
  final String title;

  /// 删除时是否处于锁定状态。
  final bool locked;

  /// 旧版遗留：`trash/<id>.md` 平铺文件，附件已丢失。
  final bool legacyFile;

  /// 是否已超过保留期（默认 30 天）。
  bool isExpired({Duration retention = const Duration(days: 30)}) =>
      DateTime.now().difference(deletedAt) > retention;
}

/// 应用私有备份的来源类型。
enum BackupKind {
  auto('自动备份'),
  manual('手动备份'),
  preRestore('恢复前快照');

  const BackupKind(this.label);

  final String label;

  static BackupKind ofName(String name) {
    if (name.startsWith('pre-restore-')) {
      return BackupKind.preRestore;
    }
    if (name.startsWith('manual-')) {
      return BackupKind.manual;
    }
    return BackupKind.auto;
  }
}

/// 备份目录里的一份 zip。
class BackupEntry {
  const BackupEntry({
    required this.file,
    required this.time,
    required this.kind,
  });

  final File file;
  final DateTime time;
  final BackupKind kind;

  String get path => file.path;

  String get name => p.basename(file.path);
}
