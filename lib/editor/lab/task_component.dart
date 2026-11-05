import 'package:flutter/material.dart';
import 'package:super_editor/super_editor.dart';

import '../../ui/task_check_box.dart';
import 'list_style.dart';

/// 小记的任务（待办）组件：基于官方 TaskComponent 复刻，只改记号列。
///
/// 官方组件有两处和列表行对不齐：
///  1. 默认 `defaultTaskIndentCalculator` = `(fontSize*0.6)*4*(indent+1)`，
///     15.5 字号首层就是 37.2dp，而无序/有序行是 26dp；
///  2. 勾选框再额外占了「左 14 + 框 20 + 右 8」共 42dp，正文比列表行
///     右移了 53dp，三种行混排时左边一眼就能看出参差（用户反馈）。
///
/// 这里把记号列宽统一成 [AppListMarker.width]，勾选框放进这一列里
/// （不再额外占宽），正文起点与无序/有序行完全一致；勾选框的圆心与
/// 圆点圆心同轴。其余（选择、手柄、IME、删除线）保持官方实现不动。
class XiaojiTaskComponentBuilder implements ComponentBuilder {
  const XiaojiTaskComponentBuilder(this._editor);

  final Editor _editor;

  @override
  TaskComponentViewModel? createViewModel(
    Document document,
    DocumentNode node,
  ) {
    if (node is! TaskNode) {
      return null;
    }
    final textDirection = getParagraphDirection(node.text.toPlainText());
    return TaskComponentViewModel(
      nodeId: node.id,
      createdAt: node.metadata[NodeMetadata.createdAt] as DateTime?,
      padding: EdgeInsets.zero,
      indent: node.indent,
      indentCalculator: AppListMarker.width,
      isComplete: node.isComplete,
      setComplete: (bool isComplete) {
        _editor.execute(<EditRequest>[
          ChangeTaskCompletionRequest(nodeId: node.id, isComplete: isComplete),
        ]);
      },
      text: node.text,
      textDirection: textDirection,
      textAlignment:
          textDirection == TextDirection.ltr ? TextAlign.left : TextAlign.right,
      textStyleBuilder: noStyleBuilder,
      selectionColor: const Color(0x00000000),
    );
  }

  @override
  Widget? createComponent(
    SingleColumnDocumentComponentContext componentContext,
    SingleColumnLayoutComponentViewModel componentViewModel,
  ) {
    if (componentViewModel is! TaskComponentViewModel) {
      return null;
    }
    return XiaojiTaskComponent(
      key: componentContext.componentKey,
      viewModel: componentViewModel,
    );
  }
}

class XiaojiTaskComponent extends StatefulWidget {
  const XiaojiTaskComponent({
    super.key,
    required this.viewModel,
    this.showDebugPaint = false,
  });

  final TaskComponentViewModel viewModel;
  final bool showDebugPaint;

  @override
  State<XiaojiTaskComponent> createState() => _XiaojiTaskComponentState();
}

class _XiaojiTaskComponentState extends State<XiaojiTaskComponent>
    with ProxyDocumentComponent<XiaojiTaskComponent>, ProxyTextComposable {
  final _textKey = GlobalKey();

  @override
  GlobalKey<State<StatefulWidget>> get childDocumentComponentKey => _textKey;

  @override
  TextComposable get childTextComposable =>
      childDocumentComponentKey.currentState as TextComposable;

  /// 完成态整行删除线（官方同款）。
  TextStyle _computeStyles(Set<Attribution> attributions) {
    final style = widget.viewModel.textStyleBuilder(attributions);
    return widget.viewModel.isComplete
        ? style.copyWith(
            decoration: style.decoration == null
                ? TextDecoration.lineThrough
                : TextDecoration.combine(
                    <TextDecoration>[TextDecoration.lineThrough, style.decoration!],
                  ),
          )
        : style;
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: widget.viewModel.textDirection,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 记号列：与无序/有序行同一宽度，勾选框靠右缘摆放。
          // 不读 ViewModel 的 indentCalculator：layout 复制 ViewModel 时
          // 会把它重置回官方默认实现（indent=0 时返回 0），列宽直接消失，
          // 正文就跑到行首、和列表行错开（用户反馈的「左边没有对齐」）。
          SizedBox(
            width: AppListMarker.width(
              widget.viewModel.textStyleBuilder(<Attribution>{}),
              widget.viewModel.indent,
            ),
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(
                  // 框 20dp 在 26.35 的行盒里垂直居中。
                  top: 3,
                  right: AppListMarker.checkboxRightInset,
                ),
                // 与阅读态/首页摘要共用同一个勾选框规格（见 [TaskCheckBox]）。
                child: TaskCheckBox(
                  checked: widget.viewModel.isComplete,
                  onTap: widget.viewModel.setComplete != null
                      ? () => widget.viewModel.setComplete!(
                            !widget.viewModel.isComplete,
                          )
                      : null,
                ),
              ),
            ),
          ),
          Expanded(
            child: TextComponent(
              key: _textKey,
              text: widget.viewModel.text,
              textDirection: widget.viewModel.textDirection,
              textAlign: widget.viewModel.textAlignment,
              maxLines: widget.viewModel.maxLines,
              overflow: widget.viewModel.overflow,
              textStyleBuilder: _computeStyles,
              inlineWidgetBuilders: widget.viewModel.inlineWidgetBuilders,
              textSelection: widget.viewModel.selection,
              selectionColor: widget.viewModel.selectionColor,
              highlightWhenEmpty: widget.viewModel.highlightWhenEmpty,
              underlines: widget.viewModel.createUnderlines(),
              showDebugPaint: widget.showDebugPaint,
            ),
          ),
        ],
      ),
    );
  }
}

