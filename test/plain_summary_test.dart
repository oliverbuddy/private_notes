import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/block.dart';

/// 列表摘要的纯文本转换：不能出现表格竖线、减号或行内标记。
void main() {
  test('表格：分隔行丢弃，数据行压成「·」', () {
    const String body = '| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |';
    expect(plainSummary(body), '名称 · 数量\n苹果 · 3');
  });

  test('行内标记（加粗/高亮/删除线/行内码）全部剥掉', () {
    expect(plainSummary('**粗** 和 ==高亮== 和 ~~删~~ 和 `码`'), '粗 和 高亮 和 删 和 码');
  });

  test('标题与列表记号不进摘要', () {
    expect(plainSummary('## 小节\n\n- 条目\n\n1. 编号'), '小节\n条目\n编号');
  });
}
