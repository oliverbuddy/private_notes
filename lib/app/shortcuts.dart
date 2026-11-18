import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 桌面图标长按快捷方式的桥。
///
/// Android 侧 MainActivity 把 `xiaoji.action=new_note / new_todo` 转成一次
/// 方法调用；这里只暴露两件事：启动时消费一次初始动作、运行中被动接收动作。
const MethodChannel _channel = MethodChannel('xiaoji/shortcuts');

/// 快捷方式动作。
enum QuickAction {
  /// 新建一条空白小记。
  newNote,

  /// 新建一条待办小记（正文预填 `- [ ] `）。
  newTodo,
}

/// 运行中收到的「新建小记」请求。计数递增，页面监听它即可。
final ValueNotifier<int> newNoteRequests = ValueNotifier<int>(0);

/// 运行中收到的「新建待办」请求。
final ValueNotifier<int> newTodoRequests = ValueNotifier<int>(0);

/// 冷启动时读一次快捷方式动作并消费掉。
///
/// 平台通道在纯测试环境下不存在，吞掉异常返回 null，
/// 不让快捷方式成为启动路径上的失败点。
Future<QuickAction?> consumeInitialQuickAction() async {
  try {
    final String? action = await _channel.invokeMethod<String>(
      'consumeInitialAction',
    );
    switch (action) {
      case 'new_note':
        return QuickAction.newNote;
      case 'new_todo':
        return QuickAction.newTodo;
      default:
        return null;
    }
  } catch (_) {
    return null;
  }
}

/// 应用已在后台时，用户再点快捷方式会走这里。
void listenShortcutEvents() {
  _channel.setMethodCallHandler((MethodCall call) async {
    if (call.method != 'shortcut') {
      return;
    }
    switch (call.arguments) {
      case 'new_note':
        newNoteRequests.value++;
      case 'new_todo':
        newTodoRequests.value++;
    }
  });
}
