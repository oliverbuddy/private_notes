import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:super_editor/super_editor.dart';

/// 在输入法与文档之间拦截「粘贴」。
///
/// 用户有两条粘贴路径：
/// 1. 长按正文 → 我们的浮动工具条「粘贴」；
/// 2. 直接点 Gboard 的剪贴板建议 / 键盘粘贴。
///
/// 第 2 条走 IME `commitText`，不经过工具条，也不经过 Flutter 的
/// `Clipboard`。这里比较「一次插入的文本」与页面缓存的剪贴板内容：
/// 一致就不交给文档，改由 [onPaste] 走 Markdown 解析。
class PasteImeDecorator extends DeltaTextInputClientDecorator {
  PasteImeDecorator({
    required this.shouldIntercept,
    required this.onPaste,
  });

  final bool Function(String insertedText) shouldIntercept;

  /// 同步执行解析粘贴；返回 false 表示没处理，继续走输入法默认粘贴。
  final bool Function() onPaste;

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> textEditingDeltas) {
    // Gboard 的剪贴板粘贴不是「一个 insertion delta」：实测会带一条
    // `TextEditingDeltaNonTextUpdate`（选区/输入法状态），后面才是插入；
    // 有选区时还会变成 `TextEditingDeltaReplacement`。所以把所有
    // 增/替换文本拼起来判断，而不是只看单条 delta。
    if (textEditingDeltas.isNotEmpty) {
      final StringBuffer inserted = StringBuffer();
      for (final TextEditingDelta delta in textEditingDeltas) {
        if (delta is TextEditingDeltaInsertion) {
          inserted.write(delta.textInserted);
        } else if (delta is TextEditingDeltaReplacement) {
          inserted.write(delta.replacementText);
        }
      }
      if (inserted.isNotEmpty &&
          shouldIntercept(inserted.toString()) &&
          onPaste()) {
        debugPrint('[paste] 拦截 IME 粘贴（${inserted.length} 字），已转为 Markdown');
        return;
      }
    }
    super.updateEditingValueWithDeltas(textEditingDeltas);
  }
}
