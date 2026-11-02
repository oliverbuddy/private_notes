import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/editor/editor_page.dart';
import 'package:xiaoji/editor/markdown_view.dart';
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/theme/app_theme.dart';

/// 编辑页滚动的回归：**不能因为聚焦或删一行就把页面滚走**。
///
/// 背景（用户实测）：磁盘上的一篇笔记通常只有一个大 TextBlock（几十行都在
/// 同一块里），它比视口还高。早先的 `_ensureVisible` 拿整块的矩形判断可见性，
/// 块顶永远在视口上方 → 每次请求焦点都把页面滚到块的开头，看起来就是
/// 「删掉列表里一行，页面跳到最上面」。现在改成只看光标矩形。
Future<void> _pumpFrames(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Finder get _blockList => find.byWidgetPredicate(
      (Widget w) => w is ListView && w.scrollDirection == Axis.vertical,
    );

double _offset(WidgetTester tester) {
  final list = tester.widget<ListView>(_blockList);
  return list.controller?.position.pixels ?? -1;
}

String _listBody(int count) => List<String>.generate(
      count,
      (int i) => '${i + 1}. 列表第${i + 1}项内容',
    ).join('\n');

/// 打开编辑页，滚到内容中部（模拟用户翻到中间再操作）。
Future<void> _openScrolled(
  WidgetTester tester, {
  required String body,
  int scrollTo = 400,
}) async {
  final tempDir = Directory.systemTemp.createTempSync('xiaoji_scroll_');
  addTearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });
  late NoteRepository repository;
  await tester.runAsync(() async {
    repository = NoteRepository(
      await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji')),
    );
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
        // 键盘已弹起（工具条可见，可视区被压矮）。
        data: const MediaQueryData(
          size: Size(400, 800),
          viewInsets: EdgeInsets.only(bottom: 280),
        ),
        child: EditorPage(
          repository: repository,
          note: Note(
            id: 'scroll',
            created: DateTime(2026, 11, 1, 9),
            updated: DateTime(2026, 11, 1, 9),
            body: body,
          ),
        ),
      ),
    ),
  );
  await _pumpFrames(tester);

  tester.widget<ListView>(_blockList).controller!.jumpTo(scrollTo.toDouble());
  await _pumpFrames(tester, frames: 10);
}

void main() {
  testWidgets('滚到中部后点正文进编辑，页面不跳回顶部', (WidgetTester tester) async {
    await _openScrolled(tester, body: _listBody(30));
    final before = _offset(tester);
    expect(before, greaterThan(300), reason: '前置条件：确实滚到了中部');

    await tester.tap(find.byType(MarkdownBlockView).first);
    await _pumpFrames(tester, frames: 12);

    expect(
      (_offset(tester) - before).abs(),
      lessThan(8),
      reason: '光标本来就在可视区里，聚焦不该让页面移动',
    );
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('在大块里删掉一行，滚动位置保持不动', (WidgetTester tester) async {
    await _openScrolled(tester, body: _listBody(30));
    await tester.tap(find.byType(MarkdownBlockView).first);
    await _pumpFrames(tester, frames: 12);
    final before = _offset(tester);

    final controller =
        tester.widget<TextField>(find.byType(TextField)).controller!;
    final text = controller.text;
    // 删掉「第二十项」那一行前后的换行 —— 等价于在该行行首按一次退格。
    final lineStart = text.indexOf('20. ');
    final cut = text.lastIndexOf('\n', lineStart);
    expect(cut, greaterThan(0));
    controller.value = TextEditingValue(
      text: text.replaceRange(cut, cut + 1, ''),
      selection: TextSelection.collapsed(offset: cut),
    );
    await _pumpFrames(tester, frames: 12);

    expect(
      (_offset(tester) - before).abs(),
      lessThan(8),
      reason: '删一行只是内容变短，视口不该挪到别处',
    );
    expect(find.byType(TextField), findsOneWidget, reason: '仍在编辑态');
  });

  testWidgets('键盘逐帧升起，滚动位置纹丝不动（弹工具栏不顶内容）', (WidgetTester tester) async {
    final tempDir = Directory.systemTemp.createTempSync('xiaoji_scroll_');
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });
    late NoteRepository repository;
    await tester.runAsync(() async {
      repository = NoteRepository(
        await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji')),
      );
    });

    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 2.0;
    tester.view.padding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: EditorPage(
          repository: repository,
          note: Note(
            id: 'scroll-kb',
            created: DateTime(2026, 11, 1, 9),
            updated: DateTime(2026, 11, 1, 9),
            body: _listBody(30),
          ),
        ),
      ),
    );
    await _pumpFrames(tester);

    // 停在笔记底部（输入时最常见的位置，也是最容易触发 clamp 的位置）。
    tester
        .widget<ListView>(_blockList)
        .controller!
        .jumpTo(tester.widget<ListView>(_blockList).controller!.position.maxScrollExtent);
    await _pumpFrames(tester, frames: 6);
    final before = _offset(tester);

    // 键盘逐帧升起（真实设备上 viewInsets 是逐帧动画值）。
    for (final inset in const <double>[30, 80, 140, 200, 250, 280]) {
      tester.view.viewInsets = FakeViewPadding(bottom: inset);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await _pumpFrames(tester, frames: 6);

    expect(
      (_offset(tester) - before).abs(),
      lessThan(1),
      reason: '键盘/工具栏升起只是视口变矮，内容高度没变，滚动位置不该被顶动',
    );
  });
}
