import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/models/note_settings.dart';
import 'package:xiaoji/reminders/reminder_scheduler.dart';
import 'package:xiaoji/reminders/reminder_service.dart';

class _FakeScheduler implements ReminderScheduler {
  List<ReminderItem> lastItems = const <ReminderItem>[];
  bool initialized = false;

  @override
  Future<void> initialize({
    required void Function(String noteId) onOpenNote,
  }) async {
    initialized = true;
  }

  @override
  Future<ReminderPermission> ensurePermissions() async =>
      ReminderPermission.granted;

  @override
  Future<void> sync(List<ReminderItem> items) async {
    lastItems = items;
  }

  @override
  Future<String?> consumeLaunchNoteId() async => null;
}

void main() {
  final DateTime base = DateTime(2026, 11, 8, 9, 0);

  group('Note.remindAt 编解码', () {
    test('设置提醒时写入 frontmatter 并往返保持', () {
      final Note note = Note(
        id: '20261108-0900-abcd',
        created: base,
        updated: base,
        remindAt: DateTime(2026, 11, 10, 20, 30),
        body: '正文',
      );
      final String raw = note.encode();
      expect(raw, contains('remind: 2026-11-10T20:30:00'));

      final Note decoded =
          Note.decode(raw, fallbackId: note.id)!;
      expect(decoded.remindAt, DateTime(2026, 11, 10, 20, 30));
      expect(decoded.body, '正文');
    });

    test('没有提醒时不多写字段（避免无意义 diff）', () {
      final Note note = Note(id: 'n', created: base, updated: base);
      expect(note.encode(), isNot(contains('remind:')));
    });

    test('clearRemind 能真正清空提醒', () {
      final Note note = Note(
        id: 'n',
        created: base,
        updated: base,
        remindAt: DateTime(2026, 11, 10, 9, 0),
      );
      expect(note.copyWith(clearRemind: true).remindAt, isNull);
      expect(
        note.copyWith(remindAt: DateTime(2026, 11, 11, 9, 0)).remindAt,
        DateTime(2026, 11, 11, 9, 0),
      );
    });
  });

  group('提醒调度项', () {
    test('只取未来提醒，按时间升序', () {
      final Note past = Note(
        id: 'past',
        created: base,
        updated: base,
        remindAt: base.subtract(const Duration(hours: 1)),
        body: '已经过期',
      );
      final Note later = Note(
        id: 'later',
        created: base,
        updated: base,
        remindAt: base.add(const Duration(days: 2)),
        body: '后天',
      );
      final Note sooner = Note(
        id: 'sooner',
        created: base,
        updated: base,
        remindAt: base.add(const Duration(hours: 3)),
        body: '三小时后\n正文',
      );
      final List<ReminderItem> items = ReminderService.reminderItemsFromNotes(
        <Note>[past, later, sooner],
        now: base,
      );
      expect(items.map((ReminderItem i) => i.noteId), <String>['sooner', 'later']);
      expect(items.first.title, '三小时后');
      expect(items.first.body, '正文');
    });

    test('锁定笔记的通知内容脱敏', () {
      final Note locked = Note(
        id: 'lock',
        created: base,
        updated: base,
        locked: true,
        remindAt: base.add(const Duration(hours: 1)),
      );
      final ReminderItem item = ReminderService.reminderItemsFromNotes(
        <Note>[locked],
        now: base,
      ).single;
      expect(item.title, '小记提醒');
      expect(item.body, contains('锁定'));
      expect(item.body, isNot(contains('正文')));
    });
  });

  group('错过提醒', () {
    test('只返回 since 与 now 之间到期的提醒', () {
      final Note old = Note(
        id: 'old',
        created: base,
        updated: base,
        remindAt: base.subtract(const Duration(days: 2)),
      );
      final Note missed = Note(
        id: 'missed',
        created: base,
        updated: base,
        remindAt: base.subtract(const Duration(hours: 1)),
      );
      final Note future = Note(
        id: 'future',
        created: base,
        updated: base,
        remindAt: base.add(const Duration(hours: 1)),
      );
      final List<Note> result = ReminderService.missedReminders(
        <Note>[old, missed, future],
        since: base.subtract(const Duration(hours: 2)),
        now: base,
      );
      expect(result.map((Note n) => n.id), <String>['missed']);
    });

    test('首次运行（since 为空）不补历史提醒', () {
      final Note missed = Note(
        id: 'missed',
        created: base,
        updated: base,
        remindAt: base.subtract(const Duration(hours: 1)),
      );
      expect(
        ReminderService.missedReminders(<Note>[missed], since: null, now: base),
        isEmpty,
      );
    });
  });

  test('ReminderService 把未来提醒交给调度器', () async {
    final _FakeScheduler fake = _FakeScheduler();
    final ReminderService service = ReminderService(scheduler: fake);
    final Note note = Note(
      id: 'n',
      created: base,
      updated: base,
      remindAt: DateTime.now().add(const Duration(hours: 1)),
      body: '记得',
    );
    await service.sync(<Note>[note]);
    expect(fake.lastItems, hasLength(1));
    expect(fake.lastItems.single.noteId, 'n');
  });

  test('设置文件往返保留 lastReminderSeenAt', () {
    final NoteSettings settings = const NoteSettings().copyWith(
      lastReminderSeenAt: '2026-11-08T09:00:00',
    );
    final NoteSettings decoded = NoteSettings.fromJson(settings.toJson());
    expect(decoded.lastReminderSeenAt, '2026-11-08T09:00:00');
  });
}
