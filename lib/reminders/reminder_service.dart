import 'package:flutter/foundation.dart';

import '../models/note.dart';
import 'reminder_scheduler.dart';

/// 提醒业务层：把笔记里的 `remindAt` 翻译成系统通知，并处理「错过提醒」。
///
/// 只依赖 [ReminderScheduler] 接口，不感知 Android/iOS/PC 差异；测试里可以
/// 注入假的 scheduler，不碰原生插件。
class ReminderService {
  ReminderService({ReminderScheduler? scheduler})
      : _scheduler = scheduler ?? LocalNotificationsReminderScheduler();

  final ReminderScheduler _scheduler;

  /// 通知点击后希望打开的笔记 id（首页监听它做深链）。
  final ValueNotifier<String?> openNoteRequest = ValueNotifier<String?>(null);

  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    await _scheduler.initialize(
      onOpenNote: (String noteId) => openNoteRequest.value = noteId,
    );
    final String? launchId = await _scheduler.consumeLaunchNoteId();
    if (launchId != null) {
      openNoteRequest.value = launchId;
    }
  }

  Future<ReminderPermission> ensurePermissions() async {
    await initialize();
    return _scheduler.ensurePermissions();
  }

  /// 全量对账（幂等）：把所有未到期的提醒写进系统通知。
  Future<void> sync(Iterable<Note> notes) async {
    await initialize();
    await _scheduler.sync(reminderItemsFromNotes(notes));
  }

  /// 从笔记里挑出未来提醒，转成调度项。
  ///
  /// 锁定笔记的正文在列表内存里是空串，这里统一脱敏：标题固定、
  /// 正文只提示「点击查看」，避免锁屏通知泄露内容。
  static List<ReminderItem> reminderItemsFromNotes(
    Iterable<Note> notes, {
    DateTime? now,
  }) {
    final DateTime reference = now ?? DateTime.now();
    final List<ReminderItem> items = <ReminderItem>[];
    for (final Note note in notes) {
      final DateTime? at = note.remindAt;
      if (at == null || !at.isAfter(reference)) {
        continue;
      }
      if (note.locked) {
        items.add(ReminderItem(
          noteId: note.id,
          at: at,
          title: '小记提醒',
          body: '有一条锁定小记的提醒，点击查看',
        ));
        continue;
      }
      items.add(ReminderItem(
        noteId: note.id,
        at: at,
        title: _firstLine(note.body),
        body: _preview(note.body),
      ));
    }
    items.sort((ReminderItem a, ReminderItem b) => a.at.compareTo(b.at));
    return items;
  }

  /// 找出「上次检查之后、现在之前」到期的提醒。
  ///
  /// [since] 为 null（首次运行）时不返回任何历史提醒，避免把几个月前的
  /// 过期提醒一次性糊到用户脸上。
  static List<Note> missedReminders(
    Iterable<Note> notes, {
    required DateTime? since,
    DateTime? now,
  }) {
    if (since == null) {
      return const <Note>[];
    }
    final DateTime reference = now ?? DateTime.now();
    final List<Note> missed = <Note>[];
    for (final Note note in notes) {
      final DateTime? at = note.remindAt;
      if (at == null || at.isAfter(reference) || !at.isAfter(since)) {
        continue;
      }
      missed.add(note);
    }
    missed.sort((Note a, Note b) => b.remindAt!.compareTo(a.remindAt!));
    return missed;
  }

  static String _firstLine(String body) {
    for (final String raw in body.split('\n')) {
      final String line = raw.trim();
      if (line.isEmpty) {
        continue;
      }
      final String cleaned = line
          .replaceFirst(RegExp(r'^#{1,6}\s*'), '')
          .replaceFirst(RegExp(r'^[-*+]\s+(\[[ xX]\]\s+)?'), '')
          .replaceFirst(RegExp(r'^>\s*'), '');
      if (cleaned.trim().isEmpty) {
        continue;
      }
      return cleaned.trim().length > 40
          ? '${cleaned.trim().substring(0, 40)}…'
          : cleaned.trim();
    }
    return '小记提醒';
  }

  static String _preview(String body) {
    final List<String> lines = body
        .split('\n')
        .map((String line) => line.trim())
        .where((String line) => line.isNotEmpty)
        .toList();
    if (lines.length <= 1) {
      return '点击查看这条小记';
    }
    final String joined = lines.skip(1).take(2).join(' ');
    return joined.length > 80 ? '${joined.substring(0, 80)}…' : joined;
  }
}

/// 全局单例：启动、编辑页保存、首页删除等入口共用一个实例。
final ReminderService reminderService = ReminderService();
