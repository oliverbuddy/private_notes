import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_editor/super_editor.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/editor/lab/markdown_paste.dart';
import 'package:xiaoji/editor/lab/new_editor_page.dart';
import 'package:xiaoji/models/note.dart';
import 'package:xiaoji/theme/app_theme.dart';

/// 粘贴 Markdown 必须**立刻**按样式进文档，不能等用户点一下才生效。
///
/// 直接调用 [MarkdownPaster.pasteContent]（同步路径）：页面里的 ⌘V 只是
/// 读取剪贴板的外壳，真正的解析/落块都在这个方法里，同步验证更稳。
Future<void> _pumpFrames(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  late Directory tempDir;
  late NoteRepository repository;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('xiaoji_paste_render_');
    final NoteStore store =
        await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
    repository = NoteRepository(store);
    await repository.load();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets('粘贴后加粗/行内码/删除线/高亮/链接全部立即生效', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: NewEditorPage(
          repository: repository,
          note: Note(
            id: 'paste-render',
            created: DateTime(2026, 11, 1),
            updated: DateTime(2026, 11, 1),
            body: '',
          ),
          autoFocus: true,
        ),
      ),
    );
    await _pumpFrames(tester);

    final Editor editor =
        tester.widget<SuperEditor>(find.byType(SuperEditor)).editor;
    final MutableDocument document = editor.document;
    final MutableDocumentComposer composer = editor.composer;
    final CommonEditorOperations ops = CommonEditorOperations(
      document: document,
      editor: editor,
      composer: composer,
      documentLayoutResolver: () => throw UnimplementedError('粘贴只做文档操作，不需要布局'),
    );

    final bool handled = MarkdownPaster(
      editor: editor,
      document: document,
      composer: composer,
      ops: ops,
    ).pasteContent(
      const ClipboardContent(
        text: '**重点加粗** 和 `行内码` 和 ~~删除线~~ 和 ==高亮== 和 [链接](https://a.com)',
      ),
    );
    await _pumpFrames(tester);
    expect(handled, isTrue);

    final TextNode node = document.first as TextNode;
    final String text = node.text.toPlainText();
    // 标记字符全部消失。
    expect(text, isNot(contains('**')));
    expect(text, isNot(contains('`')));
    expect(text, isNot(contains('~~')));
    expect(text, isNot(contains('==')));

    // 每种标签都带上了对应属性（不用点击、不用重新选中）。
    final Set<String> at = node.text
        .getAllAttributionsAt(text.indexOf('重点'))
        .map((Attribution a) => a.toString())
        .toSet();
    expect(at, contains(boldAttribution.toString()));
    expect(
      node.text
          .getAllAttributionsAt(text.indexOf('行内码'))
          .contains(codeAttribution),
      isTrue,
    );
    expect(
      node.text
          .getAllAttributionsAt(text.indexOf('删除线'))
          .contains(strikethroughAttribution),
      isTrue,
    );
    expect(
      node.text
          .getAllAttributionsAt(text.indexOf('高亮'))
          .whereType<NamedAttribution>()
          .any((NamedAttribution a) => a.name == 'highlight'),
      isTrue,
    );
    expect(
      node.text
          .getAllAttributionsAt(text.indexOf('链接'))
          .whereType<LinkAttribution>()
          .single
          .plainTextUri,
      'https://a.com',
    );

    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 6));
  });
}
