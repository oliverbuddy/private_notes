import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 桌面图标长按快捷方式的桥。
///
/// Android 侧 MainActivity 把 `xiaoji.action=new_note` 转成一次方法调用；
/// 这里只暴露两件事：启动时消费一次初始动作、运行中被动接收动作。
const MethodChannel _channel = MethodChannel('xiaoji/shortcuts');

/// 运行中收到的「新建」请求。计数递增，页面监听它即可。
final ValueNotifier<int> newNoteRequests = ValueNotifier<int>(0);

/// 冷启动时读一次快捷方式动作并消费掉。
///
/// 平台通道在纯测试环境下不存在，吞掉异常返回 false，
/// 不让快捷方式成为启动路径上的失败点。
Future<bool> consumeInitialNewNote() async {
  try {
    final action = await _channel.invokeMethod<String>('consumeInitialAction');
    return action == 'new_note';
  } catch (_) {
    return false;
  }
}

/// 应用已在后台时，用户再点快捷方式会走这里。
void listenShortcutEvents() {
  _channel.setMethodCallHandler((MethodCall call) async {
    if (call.method == 'shortcut' && call.arguments == 'new_note') {
      newNoteRequests.value++;
    }
  });
}
