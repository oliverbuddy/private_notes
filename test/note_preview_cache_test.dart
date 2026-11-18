import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/block.dart';
import 'package:xiaoji/home/note_preview_cache.dart';
import 'package:xiaoji/models/note.dart';

Note _note(String id, String body, {bool locked = false}) {
  return Note(
    id: id,
    created: DateTime(2026, 11, 1),
    updated: DateTime(2026, 11, 1),
    body: body,
    locked: locked,
  );
}

void _expectSegmentsEqual(
  List<NotePreviewSegment> actual,
  List<NotePreviewSegment> expected,
) {
  expect(actual.length, expected.length);
  for (var i = 0; i < expected.length; i++) {
    expect(actual[i].text, expected[i].text);
    expect(actual[i].rows, equals(expected[i].rows));
  }
}

void main() {
  const String heroBody = '''
# 周五回顾

这周把备份链路理顺了，下面是两张表：

| 项目 | 状态 |
|---|---|
| 自动备份 | 完成 |

![](assets/demo/1.jpg)

[报告.pdf](assets/demo/报告.pdf)
''';

  test('缓存结果与原有派生函数逐项一致', () {
    final Note note = _note('mixed', heroBody);
    final NotePreviewData data = notePreviewCache.of(note);

    _expectSegmentsEqual(data.segments, previewSegmentsOf(heroBody));
    expect(data.plainText, plainSummary(bodyWithoutTables(heroBody)));
    expect(
      data.images.map((ImageBlock image) => image.path).toList(),
      imageBlocksOf(heroBody).map((ImageBlock image) => image.path).toList(),
    );
    expect(data.hasAttachment, hasLocalAttachment(heroBody));
    expect(data.firstLine, '周五回顾');
  });

  test('同一篇笔记重复访问命中同一实例', () {
    final Note note = _note('hit', '同一段正文');

    expect(identical(notePreviewCache.of(note), notePreviewCache.of(note)), isTrue);
  });

  test('正文内容相同但字符串实例不同也能命中缓存', () {
    final Note first = _note('same-body', String.fromCharCodes('同样内容'.codeUnits));
    final Note second = _note('same-body', String.fromCharCodes('同样内容'.codeUnits));

    final NotePreviewData a = notePreviewCache.of(first);
    final NotePreviewData b = notePreviewCache.of(second);

    expect(identical(first.body, second.body), isFalse);
    expect(identical(a, b), isTrue);
  });

  test('正文变化后缓存自动失效', () {
    final Note before = _note('changed', '# 旧标题');
    final NotePreviewData oldData = notePreviewCache.of(before);
    expect(oldData.firstLine, '旧标题');

    final Note after = before.copyWith(body: '# 新标题');
    final NotePreviewData newData = notePreviewCache.of(after);

    expect(identical(oldData, newData), isFalse);
    expect(newData.firstLine, '新标题');
  });

  test('锁定笔记不解析正文', () {
    final NotePreviewData data =
        notePreviewCache.of(_note('locked', '机密正文', locked: true));

    expect(data.segments, isEmpty);
    expect(data.images, isEmpty);
    expect(data.hasAttachment, isFalse);
    expect(data.plainText, isEmpty);
    expect(data.firstLine, isEmpty);
  });

  test('空正文返回安全的空结果', () {
    final NotePreviewData data = notePreviewCache.of(_note('empty', ''));

    expect(data.segments, isEmpty);
    expect(data.images, isEmpty);
    expect(data.hasAttachment, isFalse);
    expect(data.firstLine, isEmpty);
  });

  test('超过容量时淘汰最久未使用的条目', () {
    final NotePreviewCache cache = NotePreviewCache(maxEntries: 2);
    final Note a = _note('a', 'A');
    final Note b = _note('b', 'B');
    final Note c = _note('c', 'C');

    final NotePreviewData firstA = cache.of(a);
    cache.of(b);
    cache.of(c);
    // a 已被淘汰：再次访问会重新构建。
    expect(identical(firstA, cache.of(a)), isFalse);
    // b 也已被淘汰，c 仍在。
    expect(identical(cache.of(b), cache.of(b)), isTrue);
  });

  test('行数测量缓存可读写且命中同一结果', () {
    final NotePreviewData data = notePreviewCache.of(_note('lines', '正文'));
    expect(data.lineCountOf('k'), isNull);
    data.rememberLineCount('k', 3);
    expect(data.lineCountOf('k'), 3);
  });

  test('微基准：缓存命中 vs 每次重新解析（只打印，不做时间断言）', () {
    final Note note = _note('bench', heroBody);
    // 预热。
    notePreviewCache.of(note);

    final Stopwatch cached = Stopwatch()..start();
    for (var i = 0; i < 1000; i++) {
      notePreviewCache.of(note);
    }
    cached.stop();

    final Stopwatch direct = Stopwatch()..start();
    for (var i = 0; i < 1000; i++) {
      previewSegmentsOf(note.body);
      parseBlocks(note.body);
      plainSummary(bodyWithoutTables(note.body));
    }
    direct.stop();

    // ignore: avoid_print
    print('preview cache: ${cached.elapsedMicroseconds}us, '
        'direct: ${direct.elapsedMicroseconds}us');
  });
}
