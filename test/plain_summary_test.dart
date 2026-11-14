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
}
