import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/note.dart';
import '../models/note_settings.dart';
import '../util/date_format.dart';

/// 文件布局：
///
/// ```
/// <appDocuments>/Xiaoji/
///   notes/<yyyy>/<MM>/<id>.md
///   assets/<noteId>/1.jpg
///   trash/<id>.md
///   export-YYYYMMDD-HHMM/...
///   settings.json
/// ```
///
/// 一切都在 app 的 Documents 目录下，iOS 上打开「文件」App 就能看到并拷走，
/// 这是「本地优先」最实在的兑现方式 —— 用户永远不担心数据被锁在某个账号里。
class NoteStore {
  NoteStore._(this.root);

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
    return store;
  }

  Directory get notesDir => Directory(p.join(root.path, 'notes'));

  Directory get assetsDir => Directory(p.join(root.path, 'assets'));

  Directory get trashDir => Directory(p.join(root.path, 'trash'));

  File get settingsFile => File(p.join(root.path, 'settings.json'));

  Future<void> ensureDirectories() async {
    await root.create(recursive: true);
    await notesDir.create(recursive: true);
    await assetsDir.create(recursive: true);
    await trashDir.create(recursive: true);
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
          result.add(note);
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
    final target = File(pathFor(note));
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(note.encode(), flush: true);
    await tmp.rename(target.path);
  }

  /// 删除笔记：正文移进 trash（可人工恢复），附件目录整个删掉。
  Future<void> deleteNote(Note note) async {
    final file = File(pathFor(note));
    if (await file.exists()) {
      await trashDir.create(recursive: true);
      var target = File(p.join(trashDir.path, '${note.id}.md'));
      if (await target.exists()) {
        final stamp = DateTime.now().millisecondsSinceEpoch;
        target = File(p.join(trashDir.path, '${note.id}-$stamp.md'));
      }
      try {
        await file.rename(target.path);
      } on FileSystemException {
        // 跨设备 rename 会失败，退化成复制 + 删除。
        await file.copy(target.path);
        await file.delete();
      }
    }
    final assets = assetDirectoryOf(note.id);
    if (await assets.exists()) {
      await assets.delete(recursive: true);
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
  Future<Uint8List> buildExportZip() {
    return compute(_buildExportZipSync, (notesDir.path, assetsDir.path));
  }

  /// 必须是顶层/静态函数才能进 isolate。
  static Future<Uint8List> _buildExportZipSync(
    (String, String) dirs,
  ) async {
    final (notesPath, assetsPath) = dirs;
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
        final bytes = await entity.readAsBytes();
        archive.addFile(ArchiveFile('assets/$rel', bytes.length, bytes));
      }
    }
    final encoded = ZipEncoder().encode(archive);
    return Uint8List.fromList(encoded ?? <int>[]);
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
}
