import 'package:flutter/material.dart';
import 'package:super_editor/super_editor.dart';

import '../../theme/app_theme.dart';

/// 编辑内核试验场（迁移 M0 验证专用，**临时页面**）。
///
/// 目的：在真机上验证 super_editor 的中文 IME 行为（组词、退格、光标、
/// 选择），以及 markdown ↔ 文档模型的往返是否无损。不接入主流程，
/// 迁移决策后此页面连同入口一起删除。
class EditorLabPage extends StatefulWidget {
  const EditorLabPage({super.key});

  @override
  State<EditorLabPage> createState() => _EditorLabPageState();
}

class _EditorLabPageState extends State<EditorLabPage> {
  static const _initialMarkdown = '''# 内核试验场

这是**加粗**、这是*斜体*、这是`行内码`。

1. 有序第一项
2. 有序第二项
   1. 嵌套子项一
   2. 嵌套子项二
- 无序一项
- 无序二项

- [ ] 待办：请用中文输入法打一句话
> 引用一行中文，测试光标与选择。

最后一行：组词测试用句子——今天天气不错。''';

  late final MutableDocument _document;
  late final MutableDocumentComposer _composer;
  late final Editor _editor;

  String _lastMarkdown = '';

  @override
  void initState() {
    super.initState();
    _document = deserializeMarkdownToDocument(_initialMarkdown);
    _composer = MutableDocumentComposer();
    _editor = createDefaultDocumentEditor(document: _document, composer: _composer);
  }

  @override
  void dispose() {
    _editor.dispose();
    _composer.dispose();
    _document.dispose();
    super.dispose();
  }

  void _exportMarkdown() {
    setState(() {
      _lastMarkdown = serializeDocumentToMarkdown(_document);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Scaffold(
      backgroundColor: colors.page,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              height: 48,
              child: Stack(
                children: <Widget>[
                  Center(
                    child: Text(
                      '内核试验场',
                      style: AppText.pageTitle.copyWith(
                        fontSize: AppFontSize.subtitle,
                        color: colors.text,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: InkWell(
                      onTap: () => Navigator.of(context).maybePop(),
                      child: SizedBox(
                        width: 48,
                        child: Icon(
                          Icons.arrow_back_ios_new,
                          size: 20,
                          color: colors.secondary,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: TextButton(
                      onPressed: _exportMarkdown,
                      child: Text('导出md', style: TextStyle(color: colors.accent)),
                    ),
                  ),
                ],
              ),
            ),
            Container(height: 0.5, color: colors.dividerStrong),
            Expanded(
              child: SuperEditor(
                editor: _editor,
                // 有序列表按层级换编号（1. → a. → i.），与阅读态渲染器同一套
                // 主流方案。indent 由 markdown 解析器按嵌套深度写入。
                stylesheet: defaultStylesheet.copyWith(
                  addRulesBefore: <StyleRule>[
                    StyleRule(
                      BlockSelector.all,
                      (Document doc, DocumentNode node) {
                        if (node is ListItemNode &&
                            node.type == ListItemType.ordered) {
                          if (node.indent == 1) {
                            return <String, dynamic>{
                              Styles.listNumeralStyle:
                                  OrderedListNumeralStyle.lowerAlpha,
                            };
                          }
                          if (node.indent >= 2) {
                            return <String, dynamic>{
                              Styles.listNumeralStyle:
                                  OrderedListNumeralStyle.lowerRoman,
                            };
                          }
                        }
                        return const <String, dynamic>{};
                      },
                    ),
                  ],
                ),
              ),
            ),
            if (_lastMarkdown.isNotEmpty)
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 220),
                color: colors.surface2,
                padding: const EdgeInsets.all(12),
                child: SingleChildScrollView(
                  child: Text(
                    _lastMarkdown,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: AppFontSize.caption,
                      height: 1.5,
                      color: colors.text,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
