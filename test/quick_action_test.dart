import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/app/shortcuts.dart';

/// 桌面长按快捷方式（新建小记 / 新建待办）的动作解析。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('xiaoji/shortcuts');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void mockInitialAction(String? action) {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      return call.method == 'consumeInitialAction' ? action : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  test('冷启动：new_note 映射为新建小记', () async {
    mockInitialAction('new_note');

    expect(await consumeInitialQuickAction(), QuickAction.newNote);
  });

  test('冷启动：new_todo 映射为新建待办', () async {
    mockInitialAction('new_todo');

    expect(await consumeInitialQuickAction(), QuickAction.newTodo);
  });

  test('冷启动：没有动作或未知动作返回 null', () async {
    mockInitialAction(null);
    expect(await consumeInitialQuickAction(), isNull);

    mockInitialAction('unknown');
    expect(await consumeInitialQuickAction(), isNull);
  });

  test('运行中：收到 new_todo 时递增对应计数', () async {
    listenShortcutEvents();
    final int noteBefore = newNoteRequests.value;
    final int todoBefore = newTodoRequests.value;

    await messenger.handlePlatformMessage(
      'xiaoji/shortcuts',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('shortcut', 'new_todo'),
      ),
      (_) {},
    );

    expect(newTodoRequests.value, todoBefore + 1);
    expect(newNoteRequests.value, noteBefore);
  });
}
