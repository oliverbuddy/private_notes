import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/editor/block.dart';

/// 详情页「回车续行」的回归测试。
///
/// 这条逻辑曾经完全缺失：在「1. xxx」后面回车只会得到一个空块，
/// 用户得自己再敲一次「2.」。手点很容易漏，所以钉成用例。
void main() {
  group('回车续行', () {
    test('有序列表自动递增', () {
      expect(continuationFor('1. abc').initialText, '2. ');
      expect(continuationFor('9. abc').initialText, '10. ');
      expect(continuationFor('1) abc').initialText, '2) ');
    });

    test('无序列表沿用同一个符号', () {
      expect(continuationFor('- abc').initialText, '- ');
      expect(continuationFor('* abc').initialText, '* ');
      expect(continuationFor('+ abc').initialText, '+ ');
    });

    test('待办回车后永远是未勾选', () {
      expect(continuationFor('- [ ] abc').initialText, '- [ ] ');
      // 已经勾上的项回车，新的一项不该继承勾选状态
      expect(continuationFor('- [x] abc').initialText, '- [ ] ');
      expect(continuationFor('* [X] abc').initialText, '* [ ] ');
    });

    test('引用续行', () {
      expect(continuationFor('> 引用一句').initialText, '> ');
    });

    test('普通段落不继承任何前缀', () {
      expect(continuationFor('就一句话').initialText, '');
      expect(continuationFor('就一句话').strippedBlock, '就一句话');
    });

    test('空列表项再回车退出列表', () {
      final r = continuationFor('1. ');
      expect(r.initialText, '');
      // 当前块里的「1. 」也要清掉，否则会留一个空列表项
      expect(r.strippedBlock, '');
    });

    test('空的无序列表项同样退出', () {
      expect(continuationFor('- ').initialText, '');
      expect(continuationFor('- ').strippedBlock, '');
    });

    test('缩进会被保留', () {
      expect(continuationFor('  1. abc').initialText, '  2. ');
      expect(continuationFor('  - abc').initialText, '  - ');
    });

    test('多行块只看最后一行', () {
      const block = '第一行\n1. 第二行';
      final r = continuationFor(block);
      expect(r.initialText, '2. ');
      // 前面的行必须原样保留
      expect(r.strippedBlock, block);
    });

    test('多行块的空列表项只清掉最后一行标记', () {
      const block = '上文\n- ';
      final r = continuationFor(block);
      expect(r.initialText, '');
      expect(r.strippedBlock, '上文\n');
    });

    test('待办的空项退出时也要清掉方框', () {
      final r = continuationFor('- [ ] ');
      expect(r.initialText, '');
      expect(r.strippedBlock, '');
    });

    test('标题不当作列表', () {
      expect(continuationFor('# 标题').initialText, '');
    });

    test('正文里出现数字但不是列表时不误判', () {
      expect(continuationFor('2026 年的计划').initialText, '');
      expect(continuationFor('1.5 倍').initialText, '');
    });
  });
}
