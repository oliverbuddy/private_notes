import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/util/date_format.dart';

void main() {
  group('边界：列表时间显示', () {
    final now = DateTime(2026, 10, 31, 15, 30);

    test('今天显示时分', () {
      expect(formatListTime(DateTime(2026, 10, 31, 9, 5), now: now), '09:05');
    });

    test('今天 00:00 仍显示时分', () {
      expect(formatListTime(DateTime(2026, 10, 31), now: now), '00:00');
    });

    test('今天 23:59 仍显示时分', () {
      expect(
        formatListTime(DateTime(2026, 10, 31, 23, 59), now: now),
        '23:59',
      );
    });

    test('昨天显示「昨天 + 时分」而不是日期', () {
      expect(
        formatListTime(DateTime(2026, 10, 30, 23, 59), now: now),
        '昨天 23:59',
      );
    });

    test('昨天 00:00 这个边界仍算昨天', () {
      final reference = DateTime(2026, 11, 1, 12);
      expect(
        formatListTime(DateTime(2026, 10, 31), now: reference),
        '昨天 00:00',
      );
    });

    test('前天显示月日（跨月）', () {
      expect(
        formatListTime(DateTime(2026, 10, 29, 10), now: now),
        '10月29日',
      );
    });

    test('正好 7 天前显示月日（没有「一周内」特殊分支）', () {
      expect(
        formatListTime(DateTime(2026, 10, 24, 8), now: now),
        '10月24日',
      );
    });

    test('6 天前显示月日', () {
      expect(
        formatListTime(DateTime(2026, 10, 25, 8), now: now),
        '10月25日',
      );
    });

    test('跨年显示年月日', () {
      final reference = DateTime(2026, 1, 5, 12);
      expect(
        formatListTime(DateTime(2025, 12, 31, 23), now: reference),
        '2025年12月31日',
      );
    });

    test('跨年但刚好是昨天时优先显示「昨天」', () {
      final reference = DateTime(2027, 1, 1, 10);
      expect(
        formatListTime(DateTime(2026, 12, 31, 23), now: reference),
        '昨天 23:00',
      );
    });

    test('不传 now 时按当前时间判断今天', () {
      final result = formatListTime(DateTime.now());
      expect(result, matches(RegExp(r'^\d{2}:\d{2}$')));
    });
  });

  group('边界：编辑页时间显示', () {
    final now = DateTime(2026, 10, 31, 15, 30);

    test('今天是「今天 + 时分」', () {
      expect(
        formatEditorTime(DateTime(2026, 10, 31, 9, 5), now: now),
        '今天 09:05',
      );
    });

    test('昨天是「昨天 + 时分」', () {
      expect(
        formatEditorTime(DateTime(2026, 10, 30, 22, 0), now: now),
        '昨天 22:00',
      );
    });

    test('同年是「月日 + 时分」', () {
      expect(
        formatEditorTime(DateTime(2026, 3, 1, 8, 9), now: now),
        '3月1日 08:09',
      );
    });

    test('跨年是「年月日 + 时分」', () {
      expect(
        formatEditorTime(DateTime(2025, 3, 1, 8, 9), now: now),
        '2025年3月1日 08:09',
      );
    });

    test('正好 7 天前不带相对描述', () {
      expect(
        formatEditorTime(DateTime(2026, 10, 24, 7, 0), now: now),
        '10月24日 07:00',
      );
    });
  });

  group('边界：ISO 时间读写', () {
    test('格式化补零正确', () {
      expect(
        formatIsoLocal(DateTime(2026, 1, 2, 3, 4, 5)),
        '2026-01-02T03:04:05',
      );
    });

    test('格式化与解析互逆', () {
      final value = DateTime(2026, 10, 31, 9, 12, 33);
      expect(parseIsoLocal(formatIsoLocal(value)), value);
    });

    test('容忍空格分隔的老格式', () {
      expect(
        parseIsoLocal('2026-10-31 09:12:33'),
        DateTime(2026, 10, 31, 9, 12, 33),
      );
    });

    test('空串与纯空格返回 null', () {
      expect(parseIsoLocal(''), isNull);
      expect(parseIsoLocal('   '), isNull);
    });

    test('非法内容返回 null 而不是抛异常', () {
      expect(parseIsoLocal('abc'), isNull);
      expect(parseIsoLocal('2026/10/31 09:12'), isNull);
      expect(parseIsoLocal('2026-10-31T'), isNull);
    });

    test('越界的时间串返回 null，不再被 Dart 静默归一化', () {
      // 过去这里记录的是缺陷：DateTime.tryParse 接受越界分量并进位
      // （2026-13-05 → 2027-01-05），导致 Note.decode 的兜底永远执行不到。
      // 现在 parseIsoLocal 自己做范围校验，越界一律返回 null。
      expect(parseIsoLocal('2026-13-05T10:00:00'), isNull);
      expect(parseIsoLocal('2026-02-31T00:00:00'), isNull);
      expect(parseIsoLocal('2026-10-31T25:00:00'), isNull);
      expect(parseIsoLocal('2026-10-31T09:60:00'), isNull);
      expect(parseIsoLocal('2026-10-31T09:12:60'), isNull);
      expect(parseIsoLocal('2026-00-10T09:12:00'), isNull);
      expect(parseIsoLocal('2026-10-00T09:12:00'), isNull);
    });

    test('闰年 2 月 29 日合法，平年 2 月 29 日非法', () {
      expect(parseIsoLocal('2024-02-29T00:00:00'), DateTime(2024, 2, 29));
      expect(parseIsoLocal('2026-02-29T00:00:00'), isNull);
    });

    test('省略秒与只写日期也能解析', () {
      expect(parseIsoLocal('2026-10-31T09:12'), DateTime(2026, 10, 31, 9, 12));
      expect(parseIsoLocal('2026-10-31'), DateTime(2026, 10, 31));
    });

    test('id 时间戳格式为 yyyyMMdd-HHmm', () {
      expect(formatIdStamp(DateTime(2026, 10, 31, 9, 12)), '20261031-0912');
      expect(formatExportStamp(DateTime(2026, 1, 2, 3, 4)), '20260102-0304');
    });
  });

  group('边界：isSameDay', () {
    test('同一天不同时刻返回 true', () {
      expect(
        isSameDay(DateTime(2026, 10, 31, 0, 0), DateTime(2026, 10, 31, 23, 59)),
        isTrue,
      );
    });

    test('相差一毫秒跨天返回 false', () {
      expect(
        isSameDay(
          DateTime(2026, 10, 31, 23, 59, 59, 999),
          DateTime(2026, 11, 1),
        ),
        isFalse,
      );
    });
  });

  group('边界：文件大小', () {
    test('负数按 0 B 处理', () {
      expect(formatFileSize(-1), '0 B');
    });

    test('0 字节', () {
      expect(formatFileSize(0), '0 B');
    });

    test('1023 字节仍用 B', () {
      expect(formatFileSize(1023), '1023 B');
    });

    test('1024 字节用 KB 并保留一位小数', () {
      expect(formatFileSize(1024), '1.0 KB');
    });

    test('不足 10 KB 保留一位小数', () {
      expect(formatFileSize(1024 * 9), '9.0 KB');
    });

    test('10 KB 及以上取整', () {
      expect(formatFileSize(1024 * 10), '10 KB');
    });

    test('1 MB 及以上用 MB', () {
      expect(formatFileSize(1024 * 1024), '1.0 MB');
      expect(formatFileSize(1024 * 1024 * 3 ~/ 2), '1.5 MB');
    });
  });
}
