import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/block.dart';

/// 列表摘要的纯文本转换：不能出现表格竖线、减号或行内标记。
void main() {
  test('表格：整块折叠成一行表头，分隔行与数据行不占位', () {
    const String body = '| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |';
    expect(plainSummary(body), '名称 · 数量');
  });

  test('表格：没有首尾管道的写法同样识别', () {
    const String body = '名称 | 数量\n--- | ---\n苹果 | 3';
    expect(plainSummary(body), '名称 · 数量');
  });

  test('表格：单元格里的 \\| 是内容，不拆列', () {
    const String body = '| a \\| b | 值 |\n| --- | --- |\n| x | 1 |';
    expect(plainSummary(body), 'a | b · 值');
  });

  test('表格：表头整行为空时退到首行数据', () {
    const String body = '|  |  |\n| --- | --- |\n| 苹果 | 3 |';
    expect(plainSummary(body), '苹果 · 3');
  });

  test('表格：单列表格也可读', () {
    const String body = '| 名称 |\n| --- |\n| 苹果 |';
    expect(plainSummary(body), '名称');
  });

  test('分割线不被误判成表格', () {
    expect(plainSummary('正文\n\n---\n\n下一段'), '正文\n下一段');
  });

  test('行内标记（加粗/高亮/删除线/行内码）全部剥掉', () {
    expect(plainSummary('**粗** 和 ==高亮== 和 ~~删~~ 和 `码`'), '粗 和 高亮 和 删 和 码');
  });

  test('标题与列表记号不进摘要', () {
    expect(plainSummary('## 小节\n\n- 条目\n\n1. 编号'), '小节\n条目\n编号');
  });

  test('列表预览：正文开头是表格时给出迷你表格数据，最多 5 行', () {
    const String body = '\n| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |\n'
        '| 香蕉 | 5 |\n| 橙子 | 2 |\n| 葡萄 | 8 |\n| 西瓜 | 1 |';
    final List<List<String>>? rows = tablePreviewOf(body);
    expect(rows, isNotNull);
    // 最多 5 行（表头 + 4 行数据），分隔行被跳过。
    expect(rows!.length, 5);
    expect(rows.first, <String>['名称', '数量']);
    expect(rows[1], <String>['苹果', '3']);
  });

  test('列表预览：正文不是以表格开头时返回 null', () {
    expect(tablePreviewOf('先写一句话\n\n| a | b |\n| --- | --- |'), isNull);
    expect(tablePreviewOf('普通正文'), isNull);
  });

  test('列表预览：剥掉单元格里的行内标记', () {
    const String body = '| **名称** | 数量 |\n| --- | --- |\n| 苹果 | 3 |';
    expect(tablePreviewOf(body)!.first.first, '名称');
  });

  test('两个表格都出现在预览段里，顺序与正文一致', () {
    const String body = '| a | b |\n| --- | --- |\n| 1 | 2 |\n\n'
        '中间正文\n\n'
        '| c | d |\n| --- | --- |\n| 3 | 4 |';
    final List<NotePreviewSegment> segments = previewSegmentsOf(body);
    expect(segments.length, 3);
    expect(segments[0].rows, isNotNull);
    expect(segments[1].text!.trim(), '中间正文');
    expect(segments[2].rows, isNotNull);
    expect(segments[2].rows!.first, <String>['c', 'd']);
  });

  test('去掉所有表格后剩下的正文用于文字摘要（第二个表格不显示）', () {
    const String body = '| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |\n\n'
        '中间的正文\n\n| a | b |\n| --- | --- |\n| 1 | 2 |\n\n结尾';
    final String stripped = bodyWithoutTables(body);
    expect(stripped.contains('苹果'), isFalse);
    expect(stripped.contains('| a |'), isFalse);
    expect(plainSummary(stripped), '中间的正文\n结尾');
  });
}
