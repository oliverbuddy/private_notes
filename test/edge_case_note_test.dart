import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/models/note.dart';

void main() {
  group('边界：标签解析', () {
    test('中文逗号能正确切分', () {
      expect(Note.parseTags('旅行，想法'), <String>['旅行', '想法']);
    });

    test('中英文逗号混用且带空格', () {
      expect(
        Note.parseTags(' 旅行 ， 想法 ,待办 '),
        <String>['旅行', '想法', '待办'],
      );
    });

    test('空字符串得到空标签列表', () {
      expect(Note.parseTags(''), isEmpty);
    });

    test('只有空格和逗号时得到空标签列表', () {
      expect(Note.parseTags('  , ，,  '), isEmpty);
    });

    test('重复标签被去掉且保持首次出现顺序', () {
      expect(Note.parseTags('a,b,a,c,b'), <String>['a', 'b', 'c']);
    });

    test('大小写不同的标签视为不同标签', () {
      expect(Note.parseTags('Flutter,flutter'), <String>['Flutter', 'flutter']);
    });
  });

  group('边界：时间戳缺失与非法', () {
    test('缺 created 时从 id 里的时间戳反推', () {
      const raw = '---\n'
          'id: 20261031-0912-a1b2\n'
          '---\n\n'
          '正文';
      final note = Note.decode(raw);
      expect(note, isNotNull);
      expect(note!.created, DateTime(2026, 10, 31, 9, 12));
    });

    test('created 非法时回退到 id 里的时间戳', () {
      const raw = '---\n'
          'id: 20261031-0912-a1b2\n'
          'created: 不是时间\n'
          '---\n\n'
          '正文';
      final note = Note.decode(raw);
      expect(note!.created, DateTime(2026, 10, 31, 9, 12));
    });

    test('缺 updated 时等于 created', () {
      const raw = '---\n'
          'id: 20261031-0912-a1b2\n'
          'created: 2026-10-31T09:12:00\n'
          '---\n\n'
          '正文';
      final note = Note.decode(raw);
      expect(note!.updated, note.created);
    });

    test('updated 早于 created 时被抬到 created', () {
      const raw = '---\n'
          'id: 20261031-0912-a1b2\n'
          'created: 2026-10-31T09:12:00\n'
          'updated: 2026-10-30T09:12:00\n'
          '---\n\n'
          '正文';
      final note = Note.decode(raw);
      expect(note!.updated, note.created);
    });

    test('id 也不含时间戳时仍能解析出笔记（时间回落到当前时刻）', () {
      const raw = '---\nid: 手工改过的名字\n---\n\n正文';
      final note = Note.decode(raw);
      expect(note, isNotNull);
      expect(note!.id, '手工改过的名字');
      expect(note.created.year, greaterThanOrEqualTo(2020));
    });

    test('id 里月份越界时不再归一化，回落到当前时间', () {
      // _parseFromId 现在显式校验 1..12；13 月直接返回 null，不再变成次年 1 月。
      const raw = '---\nid: 20261331-0000-abcd\n---\n\n正文';
      final note = Note.decode(raw);
      expect(note, isNotNull);
      expect(
        note!.created.difference(DateTime.now()).inMinutes.abs(),
        lessThan(2),
      );
    });

    test('id 里小时越界时不再归一化，回落到当前时间', () {
      const raw = '---\nid: 20261031-2500-abcd\n---\n\n正文';
      final note = Note.decode(raw);
      expect(
        note!.created.difference(DateTime.now()).inMinutes.abs(),
        lessThan(2),
      );
    });

    test('id 里 2 月 31 日不再被归一化，回落到当前时间', () {
      // 原先只校验 day ∈ 1..31，2 月 31 日会被 DateTime 静默归一化成 3 月 3 日。
      // 现在按「当月真实天数」校验，越界直接返回 null。
      const raw = '---\nid: 20260231-0000-abcd\n---\n\n正文';
      final note = Note.decode(raw);
      expect(note, isNotNull);
      expect(
        note!.created.difference(DateTime.now()).inMinutes.abs(),
        lessThan(2),
      );
    });

    // 回归：frontmatter 里的越界时间也必须回退到 id 反推的时间。
    // 注意这条路径走的是 parseIsoLocal（util/date_format.dart），
    // 不是 _parseFromId —— 两者都要能挡住越界值。
    for (final created in <String>[
      '2026-13-05T10:00:00', // 13 月
      '2026-02-31T00:00:00', // 2 月 31 日
      '2026-10-31T25:00:00', // 25 时
    ]) {
      test('created: $created 必须回退到 id 反推的时间', () {
        final raw = '---\n'
            'id: 20261031-0912-a1b2\n'
            'created: $created\n'
            '---\n\n'
            '正文';
        final note = Note.decode(raw);
        expect(note, isNotNull);
        expect(
          note!.created,
          DateTime(2026, 10, 31, 9, 12),
          reason: '越界时间不能被 Dart 静默归一化，应回退到 id 里的时间戳',
        );
      });
    }
  });

  group('边界：frontmatter 结构', () {
    test('只有 id 一个字段时其余字段取默认值', () {
      const raw = '---\nid: 20261031-0912-a1b2\n---\n\n正文';
      final note = Note.decode(raw);
      expect(note, isNotNull);
      expect(note!.tags, isEmpty);
      expect(note.pinned, isFalse);
      expect(note.body, '正文');
    });

    test('id 为空且没有 fallbackId 时返回 null', () {
      const raw = '---\nid:\n---\n\n正文';
      expect(Note.decode(raw), isNull);
    });

    test('id 为空但有 fallbackId 时使用 fallbackId', () {
      const raw = '---\nid:\n---\n\n正文';
      final note = Note.decode(raw, fallbackId: '20260101-0000-aaaa');
      expect(note!.id, '20260101-0000-aaaa');
    });

    test('带 BOM 的文件能正常解析', () {
      const raw = '\uFEFF---\nid: 20261031-0912-a1b2\n---\n\n正文';
      final note = Note.decode(raw);
      expect(note, isNotNull);
      expect(note!.body, '正文');
    });

    test('缺少闭合 --- 时返回 null 而不是抛异常', () {
      expect(Note.decode('---\nid: abc\n正文'), isNull);
    });

    test('只有 --- 一行时返回 null', () {
      expect(Note.decode('---'), isNull);
    });

    test('正文里的 --- 分隔线不会被当作文档结尾', () {
      const raw = '---\n'
          'id: 20261031-0912-a1b2\n'
          '---\n\n'
          '正文\n'
          '---\n'
          '后续';
      final note = Note.decode(raw);
      expect(note!.body, '正文\n---\n后续');
    });

    test('正文为空时解析出空 body', () {
      const raw = '---\nid: 20261031-0912-a1b2\n---\n\n';
      final note = Note.decode(raw);
      expect(note!.body, '');
    });

    test('pinned 值大小写不敏感', () {
      const raw = '---\nid: a\npinned: TRUE\n---\n\n正文';
      expect(Note.decode(raw)!.pinned, isTrue);
    });

    test('pinned 值非 true 时按 false 处理', () {
      const raw = '---\nid: a\npinned: yes\n---\n\n正文';
      expect(Note.decode(raw)!.pinned, isFalse);
    });
  });

  group('边界：编码往返', () {
    test('空正文的笔记编码再解码后正文仍为空', () {
      final note = Note(
        id: '20261031-0912-a1b2',
        created: DateTime(2026, 10, 31, 9, 12),
        updated: DateTime(2026, 10, 31, 9, 12),
      );
      final decoded = Note.decode(note.encode());
      expect(decoded!.body, '');
    });

    test('正文以换行开头时往返不丢行', () {
      final note = Note(
        id: '20261031-0912-a1b2',
        created: DateTime(2026, 10, 31, 9, 12),
        updated: DateTime(2026, 10, 31, 9, 12),
        body: '\n开头就是空行',
      );
      expect(Note.decode(note.encode())!.body, '\n开头就是空行');
    });

    test('中文正文与中文标签往返无损', () {
      final note = Note(
        id: '20261031-0912-a1b2',
        created: DateTime(2026, 10, 31, 9, 12),
        updated: DateTime(2026, 10, 31, 9, 12),
        tags: const <String>['旅行', '想法'],
        body: '今天去了西湖，人很多。\n\n![](assets/x/1.jpg)',
      );
      final decoded = Note.decode(note.encode())!;
      expect(decoded.body, note.body);
      expect(decoded.tags, note.tags);
    });

    test('generateId 生成的时间戳前缀能被反推回创建时间', () {
      final now = DateTime(2026, 10, 31, 9, 12, 45);
      final id = Note.generateId(now);
      expect(id, startsWith('20261031-0912-'));
      final note = Note(id: id, created: now, updated: now);
      expect(Note.decode(note.encode())!.created, now);
    });

    test('copyWith 不改变未传入的字段', () {
      final note = Note(
        id: 'a',
        created: DateTime(2026, 1, 1),
        updated: DateTime(2026, 1, 2),
        tags: const <String>['x'],
        pinned: true,
        body: '正文',
      );
      final next = note.copyWith(pinned: false);
      expect(next.id, note.id);
      expect(next.created, note.created);
      expect(next.updated, note.updated);
      expect(next.tags, note.tags);
      expect(next.body, note.body);
      expect(next.pinned, isFalse);
    });
  });
}
