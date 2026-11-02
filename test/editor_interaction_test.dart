import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/editor/editor_page.dart';
import 'package:xiaoji/editor/markdown_shortcut_formatter.dart';
import 'package:xiaoji/editor/markdown_view.dart';
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/theme/app_theme.dart';

/// 编辑页交互的回归：退格合并后的焦点、撤销重做、Markdown 快捷输入、
/// 代码围栏内的回车、以及工具栏命令。
///
/// 这些用例统一给 EditorPage 套一个带 `viewInsets.bottom` 的 MediaQuery，
/// 模拟「键盘已经弹起」—— 否则工具条处于滑出状态且被 IgnorePointer 挡住，
/// 点不到按钮。
Future<void> _pumpFrames(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Directory _tempRoot(String prefix) {
  final tempDir = Directory.systemTemp.createTempSync(prefix);
  addTearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });
  return Directory('${tempDir.path}/Xiaoji');
}

/// 打开编辑页并聚焦第一块（相当于用户点了一下正文）。
Future<TextEditingController> _openEditor(
  WidgetTester tester, {
  required String body,
}) async {
  final root = _tempRoot('xiaoji_edit_');
  late NoteRepository repository;
  await tester.runAsync(() async {
    repository = NoteRepository(await NoteStore.openAt(root));
  });

  // 物理窗口（tester 默认 800x600）必须和 MediaQuery 的逻辑尺寸一致：
  // resizeToAvoidBottomInset 会按真实窗口避让键盘，两者不一致时
  // 小屏假象会让浮层工具条盖住顶栏，tap 全部落空。
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: MediaQuery(
        // 模拟键盘弹起：工具条进入可见、可点状态。
        data: const MediaQueryData(
          size: Size(400, 800),
          viewInsets: EdgeInsets.only(bottom: 280),
        ),
        child: EditorPage(
          repository: repository,
          note: Note(
            id: 'editing',
            created: DateTime(2026, 11, 1, 9),
            updated: DateTime(2026, 11, 1, 9),
            body: body,
          ),
        ),
      ),
    ),
  );
  await _pumpFrames(tester, frames: 8);

  // 有内容的块以渲染态呈现（MarkdownBlockView）；空正文只有占位空块，
  // 点列表上方空白处同样能聚焦（点空白 = 聚焦最后一块）。
  final markdownBlocks = find.byType(MarkdownBlockView);
  if (markdownBlocks.evaluate().isNotEmpty) {
    await tester.tap(markdownBlocks.first);
  } else {
    await tester.tapAt(const Offset(200, 80));
  }
  await _pumpFrames(tester, frames: 8);
  return tester.widget<TextField>(find.byType(TextField)).controller!;
}

/// 模拟一次「输入法提交」：直接改控制器的值，走的是和真机同一条监听链路。
Future<void> _type(
  WidgetTester tester,
  TextEditingController controller,
  String text, {
  int? caret,
}) async {
  controller.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: caret ?? text.length),
  );
  await _pumpFrames(tester, frames: 3);
}

void main() {
  testWidgets('退格删掉空列表项（块被合并）后仍在编辑态', (WidgetTester tester) async {
    final controller = await _openEditor(tester, body: '甲');

    // 块末尾回车 → 拆成两块，新块是空的。
    await _type(tester, controller, '甲\n');
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '',
    );

    // 打一个字再删掉：块变空 → 并入上一块。
    final second = tester.widget<TextField>(find.byType(TextField)).controller!;
    await _type(tester, second, 'x');
    await _type(tester, second, '');

    // 关键：不能失去焦点（之前这里键盘收起、光标消失）。
    expect(find.byType(TextField), findsOneWidget);
    final merged = tester.widget<TextField>(find.byType(TextField));
    expect(merged.controller?.text, '甲');
    expect(merged.controller?.selection.baseOffset, 1);
    expect(merged.focusNode?.hasFocus, isTrue);
  });

  testWidgets('撤销一次退掉刚打的一段，光标留在这一块', (WidgetTester tester) async {
    final controller = await _openEditor(tester, body: '一');

    // 回车拆块 → 第二块里继续写（连续输入属于同一段历史）。
    await _type(tester, controller, '一\n');
    final second = tester.widget<TextField>(find.byType(TextField)).controller!;
    await _type(tester, second, '二');
    await _type(tester, second, '二x');

    await tester.tap(find.byIcon(Icons.rotate_left));
    await _pumpFrames(tester, frames: 8);

    final field = tester.widget<TextField>(find.byType(TextField));
    // 回车那一步不会被一起退掉（否则光标会跳到上一段开头）。
    expect(field.controller?.text, '');
    expect(field.focusNode?.hasFocus, isTrue);
    expect(find.byType(MarkdownBlockView), findsOneWidget);
  });

  testWidgets('空列表项再回车退出列表，不额外多一个空行', (WidgetTester tester) async {
    final controller = await _openEditor(tester, body: '1. aaa');

    // 回车 → 新项 `2. `
    await _type(tester, controller, '1. aaa\n');
    // 空项再回车 → 退出列表
    final second = tester.widget<TextField>(find.byType(TextField)).controller!;
    await _type(tester, second, '2. \n');

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '',
    );
    // 只应该有原来那一块（渲染态），不额外插一个空块。
    expect(find.byType(MarkdownBlockView), findsOneWidget);
  });

  testWidgets('撤销与重做', (WidgetTester tester) async {
    final controller = await _openEditor(tester, body: '原文');

    await _type(tester, controller, '原文abc');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '原文abc',
    );

    await tester.tap(find.byIcon(Icons.rotate_left));
    await _pumpFrames(tester, frames: 8);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '原文',
    );

    await tester.tap(find.byIcon(Icons.rotate_right));
    await _pumpFrames(tester, frames: 8);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '原文abc',
    );
  });

  testWidgets('撤销会把结构变化（回车拆块）也退回去', (WidgetTester tester) async {
    final controller = await _openEditor(tester, body: '第一段');

    await _type(tester, controller, '第一段\n第二段');
    final blocks = tester
        .widgetList<MarkdownBlockView>(find.byType(MarkdownBlockView))
        .length;
    expect(blocks, 1, reason: '第一段渲染成只读块，第二段是输入框');

    await tester.tap(find.byIcon(Icons.rotate_left));
    await _pumpFrames(tester, frames: 8);

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '第一段',
    );
    expect(find.byType(MarkdownBlockView), findsNothing);
  });

  group('Markdown 快捷输入（formatter）', () {
    const MarkdownShortcutFormatter formatter = MarkdownShortcutFormatter();
    TextEditingValue value(String text) => TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );

    test('[] + 空格 → 待办', () {
      final out = formatter.formatEditUpdate(value('[]'), value('[] '));
      expect(out.text, '- [ ] ');
      expect(out.selection.baseOffset, 6);
    });

    test('[x] + 空格 → 已完成待办', () {
      expect(
        formatter.formatEditUpdate(value('[x]'), value('[x] ')).text,
        '- [x] ',
      );
    });

    test('* / + 空格 → 统一成减号', () {
      expect(formatter.formatEditUpdate(value('*'), value('* ')).text, '- ');
      expect(formatter.formatEditUpdate(value('+'), value('+ ')).text, '- ');
    });

    test('普通空格不转换', () {
      expect(
        formatter.formatEditUpdate(value('abc'), value('abc ')).text,
        'abc ',
      );
    });

    test('记号不在行首时不转换', () {
      expect(
          formatter.formatEditUpdate(value('a *'), value('a * ')).text, 'a * ');
    });
  });

  testWidgets('输入 [] 再空格自动变成待办（走输入法管线）', (WidgetTester tester) async {
    await _openEditor(tester, body: '');

    await tester.enterText(find.byType(TextField), '[] ');
    await _pumpFrames(tester, frames: 4);

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '- [ ] ',
    );
  });

  testWidgets('代码围栏里回车不拆块（否则围栏被劈成两半）', (WidgetTester tester) async {
    final controller = await _openEditor(tester, body: '```');

    await _type(tester, controller, '```\n');

    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '```\n',
    );
  });

  testWidgets('工具栏 Aa 面板套用标题后文本与光标都对', (WidgetTester tester) async {
    final controller = await _openEditor(tester, body: '标题测试');
    await _type(tester, controller, '标题测试', caret: 2);

    await tester.tap(find.text('Aa'));
    await _pumpFrames(tester, frames: 10);
    await tester.tap(find.text('H1'));
    await _pumpFrames(tester, frames: 12);

    final after = tester.widget<TextField>(find.byType(TextField));
    expect(after.controller?.text, '# 标题测试');
    // 光标原来在第 2 个字符后，加上 '# ' 前缀后就该停在第 4 个字符后。
    expect(after.controller?.selection.baseOffset, 4);
  });

  group('块类型互斥：改类型不能叠记号', () {
    Future<void> pickList(WidgetTester tester, String label) async {
      await tester.tap(find.byIcon(Icons.format_list_bulleted));
      await _pumpFrames(tester, frames: 10);
      await tester.tap(find.text(label));
      await _pumpFrames(tester, frames: 12);
    }

    String textOf(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField)).controller!.text;

    testWidgets('引用 + 有序列表 → 无序列表：换成 "- 内容"', (WidgetTester tester) async {
      await _openEditor(tester, body: '> 21. 内容');
      await pickList(tester, '无序');

      // 不能是 `-> 21. 内容`（旧实现把新记号直接插在行首）。
      expect(textOf(tester), '- 内容');
    });

    testWidgets('待办行切无序列表，不会被当成「同类」直接取消', (WidgetTester tester) async {
      await _openEditor(tester, body: '- [ ] 买牛奶');
      await pickList(tester, '无序');

      expect(textOf(tester), '- 买牛奶');
    });

    testWidgets('已经是有序列表，再点有序列表是取消', (WidgetTester tester) async {
      await _openEditor(tester, body: '3. 第三项');
      await pickList(tester, '有序');

      expect(textOf(tester), '第三项');
    });

    testWidgets('无序列表行点引用：换成 "> 内容"', (WidgetTester tester) async {
      await _openEditor(tester, body: '- 买牛奶');
      await tester.tap(find.byIcon(Icons.format_quote_rounded));
      await _pumpFrames(tester, frames: 12);

      expect(textOf(tester), '> 买牛奶');
    });

    testWidgets('标题行点「正文」只去掉标题记号', (WidgetTester tester) async {
      await _openEditor(tester, body: '## 二级标题');
      await tester.tap(find.text('Aa'));
      await _pumpFrames(tester, frames: 10);
      await tester.tap(find.text('正文'));
      await _pumpFrames(tester, frames: 12);

      expect(textOf(tester), '二级标题');
    });

    testWidgets('列表行点「正文」不会顺手把减号删掉', (WidgetTester tester) async {
      await _openEditor(tester, body: '- 买牛奶');
      await tester.tap(find.text('Aa'));
      await _pumpFrames(tester, frames: 10);
      await tester.tap(find.text('正文'));
      await _pumpFrames(tester, frames: 12);

      expect(textOf(tester), '- 买牛奶');
    });

    testWidgets('复合记号行套标题：剥掉列表与引用', (WidgetTester tester) async {
      await _openEditor(tester, body: '> 21. 内容');
      await tester.tap(find.text('Aa'));
      await _pumpFrames(tester, frames: 10);
      await tester.tap(find.text('H2'));
      await _pumpFrames(tester, frames: 12);

      expect(textOf(tester), '## 内容');
    });
  });

  testWidgets('把列表项删空后整行消失，后续编号依次减一', (WidgetTester tester) async {
    final controller = await _openEditor(tester, body: '1. a\n2. b\n3. c');

    // 逐步退格删光第二项：'2. b' → '2. ' → '2.' → '2' → 空。
    // 最后一步旧行只剩编号（纯记号），整行要被移除 —— 不留空白行，
    // 否则空行会打断编号组，第三项不再顺延（用户实测）。
    await _type(tester, controller, '1. a\n2. \n3. c');
    await _type(tester, controller, '1. a\n2.\n3. c');
    await _type(tester, controller, '1. a\n2\n3. c');
    await _type(tester, controller, '1. a\n\n3. c');

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '1. a\n2. c',
      reason: '空行被移除，第三项编号从 3 顺延成 2',
    );
    expect(find.byType(TextField), findsOneWidget, reason: '仍在编辑态');
  });

  group('插入类命令', () {
    String textOf(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField)).controller!.text;

    testWidgets('代码块按钮插入成对围栏，光标落到中间空行', (WidgetTester tester) async {
      await _openEditor(tester, body: '');
      // 代码块在「插入」弹层里（2026-11 从底栏挪入）。
      await tester.tap(find.byIcon(Icons.format_list_bulleted));
      await _pumpFrames(tester, frames: 10);
      await tester.tap(find.text('代码块'));
      await _pumpFrames(tester, frames: 10);

      expect(textOf(tester), '```\n\n```');
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller?.selection.baseOffset, 4);
    });

    testWidgets('分隔线插在当前行的下一行', (WidgetTester tester) async {
      await _openEditor(tester, body: '一段文字');
      await tester.tap(find.byIcon(Icons.format_list_bulleted));
      await _pumpFrames(tester, frames: 10);
      await tester.tap(find.text('分隔线'));
      await _pumpFrames(tester, frames: 10);

      expect(textOf(tester), '一段文字\n---');
    });

    testWidgets('缩进/减少缩进按两个空格增减行首', (WidgetTester tester) async {
      await _openEditor(tester, body: '- 甲');
      await tester.tap(find.byIcon(Icons.format_list_bulleted));
      await _pumpFrames(tester, frames: 10);
      await tester.tap(find.text('缩进'));
      await _pumpFrames(tester, frames: 10);
      expect(textOf(tester), '  - 甲');

      await tester.tap(find.byIcon(Icons.format_list_bulleted));
      await _pumpFrames(tester, frames: 10);
      await tester.tap(find.text('减少缩进'));
      await _pumpFrames(tester, frames: 10);
      expect(textOf(tester), '- 甲');

      // 顶格再点减少缩进：无变化，也不能崩。
      await tester.tap(find.byIcon(Icons.format_list_bulleted));
      await _pumpFrames(tester, frames: 10);
      await tester.tap(find.text('减少缩进'));
      await _pumpFrames(tester, frames: 10);
      expect(textOf(tester), '- 甲');
    });

    testWidgets('有序列表缩进变子列表：编号重开为 1，父级编号接续', (WidgetTester tester) async {
      await _openEditor(tester, body: '1. 甲\n2. 乙\n3. 丙');
      await tester.tap(find.byIcon(Icons.format_list_bulleted));
      await _pumpFrames(tester, frames: 10);
      await tester.tap(find.text('缩进'));
      await _pumpFrames(tester, frames: 10);

      // 「2. 乙」缩进后成为子列表首项，编号重开；「3. 丙」是父级里
      // 紧跟甲的下一项，编号接续为 2（子列表不打断父级编号）。
      expect(textOf(tester), '1. 甲\n  1. 乙\n2. 丙');
    });

    testWidgets('减少缩进后编号弹回父级序列', (WidgetTester tester) async {
      await _openEditor(tester, body: '1. 甲\n  1. 乙\n3. 丙');
      // 光标移到第二行行首再反缩进。
      final controller =
          tester.widget<TextField>(find.byType(TextField)).controller!;
      controller.selection = const TextSelection.collapsed(offset: 6);
      await tester.tap(find.byIcon(Icons.format_list_bulleted));
      await _pumpFrames(tester, frames: 10);
      await tester.tap(find.text('减少缩进'));
      await _pumpFrames(tester, frames: 10);

      // 「  1. 乙」回到父级后接续甲，变成 2；「3. 丙」顺延成 3。
      expect(textOf(tester), '1. 甲\n2. 乙\n3. 丙');
    });
  });
}
