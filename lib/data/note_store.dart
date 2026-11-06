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

  Directory get backupsDir => Directory(p.join(root.path, 'backups'));

  File get settingsFile => File(p.join(root.path, 'settings.json'));

  Future<void> ensureDirectories() async {
    await root.create(recursive: true);
    await notesDir.create(recursive: true);
    await assetsDir.create(recursive: true);
    await trashDir.create(recursive: true);
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
  Future<void> saveNote(Note note) async {
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
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(toWrite.encode(), flush: true);
    await tmp.rename(target.path);
  }

  /// 是否存在该笔记文件（用于判断恢复/覆盖场景）。
  Future<bool> noteFileExists(Note note) => File(pathFor(note)).exists();

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
      await saveNote(note);
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
    await saveNote(note);
    final assets = Directory(p.join(directory.path, 'assets'));
    if (await assets.exists()) {
      final target = assetDirectoryOf(note.id);
      if (await target.exists()) {
        await target.delete(recursive: true);
      }
      await _moveDirectory(assets, target);
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
  ];

  /// 恢复时同样跳过这些目录（旧导出包里可能带着它们）。
  static bool _isExcludedArchivePath(String path) {
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
    final file = File(p.join(backupsDir.path, name));
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.parent.create(recursive: true);
    try {
      await zipNotesToFile(
        sourceRoot: root.path,
        targetPath: tmp.path,
        excludes: _alwaysExcluded,
      );
    } on MissingPluginException {
      // 内存版只读磁盘文件，锁定笔记写进去的仍是密文。
      final bytes = await buildExportZip();
      await tmp.writeAsBytes(bytes, flush: true);
    }
    await tmp.rename(file.path);
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

  /// 只保留最近 [keep] 份 `auto-*.zip`（`pre-restore-*` 不动）。
  Future<void> pruneAutoBackups({int keep = 3}) =>
      _pruneByPrefix('auto-', keep: keep);

  /// 只保留最近 [keep] 份手动备份，避免无限堆积占满磁盘。
  Future<void> pruneManualBackups({int keep = 5}) =>
      _pruneByPrefix('manual-', keep: keep);

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

  /// 导出全部笔记到 `export-YYYYMMDD-HHMM/`。
  ///
  /// 笔记文件平铺在导出根目录，附件放 `assets/` 子目录 ——
  /// 这样正文里的 `assets/<id>/1.jpg` 相对引用在导出目录里依然能打开。
  Future<String> exportAll() async {
    final stamp = formatExportStamp(DateTime.now());
    var directory = Directory(p.join(root.path, 'export-$stamp'));
    var attempt = 2;
    while (await directory.exists()) {
      directory = Directory(p.join(root.path, 'export-$stamp-$attempt'));
      attempt += 1;
    }
    await directory.create(recursive: true);

    if (await notesDir.exists()) {
      await for (final entity
          in notesDir.list(recursive: true, followLinks: false)) {
        if (entity is! File) {
          continue;
        }
        if (!entity.path.toLowerCase().endsWith('.md')) {
          continue;
        }
        await entity.copy(p.join(directory.path, p.basename(entity.path)));
      }
    }

    if (await assetsDir.exists()) {
      await _copyTree(assetsDir, Directory(p.join(directory.path, 'assets')));
    }

    return directory.path;
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
        await saveNote(note);
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
            await saveNote(note);
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
        excludes: <String>[..._alwaysExcluded, ...excludes],
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
  manual('立即备份'),
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
