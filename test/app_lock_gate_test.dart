import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaoji/data/note_repository.dart';
import 'package:xiaoji/data/note_store.dart';
import 'package:xiaoji/security/app_lock_gate.dart';
import 'package:xiaoji/security/security_service.dart';
import 'package:xiaoji/theme/app_theme.dart';

/// 应用锁回归测试：
///
/// 系统凭证验证页是另一个 Activity，拉起时宿主会 paused、验证结束会
/// resumed。旧实现把这段生命周期当成「用户离开了 App」，自动锁定设为
/// 「立即」时验证刚通过就被重新上锁 — 用户看到的就是系统/指纹验证
/// 永远解不开。这里的用例专门守住这个顺序。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel nativeChannel = MethodChannel('xiaoji/native');
  Completer<bool>? authCompleter;

  /// 模拟原生安全通道。[deviceSecure] 控制走系统凭证还是 PIN 分支，
  /// [authenticate] 由用例通过 [authCompleter] 手动决定何时返回。
  void mockSecurityChannel(
    WidgetTester tester, {
    bool deviceSecure = true,
  }) {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(nativeChannel, (MethodCall call) async {
      switch (call.method) {
        case 'isDeviceSecure':
          return deviceSecure;
        case 'authenticate':
          authCompleter = Completer<bool>();
          return authCompleter!.future;
        case 'setSecureScreen':
          return true;
        case 'randomSalt':
          return 'c2FsdHNhbHRzYWx0c2FsdA==';
        case 'hashPin':
          return 'aGFzaGVkLXBpbg==';
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(nativeChannel, null);
    });
  }

  Future<NoteRepository> openRepository(
    WidgetTester tester, {
    required int autoLockSeconds,
  }) async {
    final Directory tempDir =
        Directory.systemTemp.createTempSync('xiaoji_lock_');
    addTearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
      authCompleter = null;
    });

    late NoteRepository repository;
    await tester.runAsync(() async {
      final store = await NoteStore.openAt(Directory('${tempDir.path}/Xiaoji'));
      repository = NoteRepository(store);
      await repository.load();
      await repository.updateSettings(
        repository.settings.copyWith(
          lockEnabled: true,
          autoLockSeconds: autoLockSeconds,
        ),
      );
    });
    return repository;
  }

  Future<void> pumpGate(
    WidgetTester tester,
    NoteRepository repository,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        builder: (BuildContext context, Widget? child) => AppLockGate(
          repository: repository,
          child: child ?? const SizedBox.shrink(),
        ),
        home: const Scaffold(
          body: Center(child: Text('笔记内容')),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> waitForAuthSheet(WidgetTester tester) async {
    for (int i = 0; i < 10 && authCompleter == null; i++) {
      await tester.pump();
    }
    expect(authCompleter, isNotNull, reason: '解锁按钮没有拉起系统验证');
  }

  /// 系统验证页盖上来时的生命周期流转（Android 上会走完整条链路）。
  Future<void> background(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
  }

  Future<void> foreground(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  }

  Future<void> unlockBySystemAuth(WidgetTester tester) async {
    await tester.tap(find.text('解锁'));
    await tester.pump();
    await waitForAuthSheet(tester);
    await background(tester);
    authCompleter!.complete(true);
    await tester.pump();
    await tester.pump();
    await foreground(tester);
    await tester.pump();
  }

  group('应用锁系统验证', () {
    testWidgets('系统凭证验证通过后，resumed 不会再次上锁', (
      WidgetTester tester,
    ) async {
      final repository = await openRepository(tester, autoLockSeconds: 0);
      mockSecurityChannel(tester);
      await pumpGate(tester, repository);

      expect(find.text('小记已锁定'), findsOneWidget);

      // 旧实现会在验证结果返回后的那次 resumed 里重新上锁。
      await unlockBySystemAuth(tester);

      expect(find.text('小记已锁定'), findsNothing);
      expect(find.text('笔记内容'), findsOneWidget);
    });

    testWidgets('验证取消/失败时保持锁定，解锁按钮可以重试', (
      WidgetTester tester,
    ) async {
      final repository = await openRepository(tester, autoLockSeconds: 0);
      mockSecurityChannel(tester);
      await pumpGate(tester, repository);

      await tester.tap(find.text('解锁'));
      await tester.pump();
      await waitForAuthSheet(tester);
      await background(tester);
      authCompleter!.complete(false);
      await tester.pump();
      await tester.pump();
      await foreground(tester);
      await tester.pump();

      expect(find.text('小记已锁定'), findsOneWidget);
      // 验证结束必须解除转圈，否则用户再也点不了「解锁」。
      expect(find.text('解锁'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('正常退到后台仍然会立即锁定', (WidgetTester tester) async {
      final repository = await openRepository(tester, autoLockSeconds: 0);
      mockSecurityChannel(tester);
      await pumpGate(tester, repository);

      await unlockBySystemAuth(tester);
      expect(find.text('小记已锁定'), findsNothing);

      // 没有系统验证在跑：退后台就该锁定。
      await background(tester);
      await foreground(tester);
      expect(find.text('小记已锁定'), findsOneWidget);
    });

    testWidgets('自动锁定 1 分钟：短时间离开不锁，超时才锁', (
      WidgetTester tester,
    ) async {
      final repository = await openRepository(tester, autoLockSeconds: 60);
      mockSecurityChannel(tester);
      await pumpGate(tester, repository);

      await unlockBySystemAuth(tester);

      // 离开时间远小于 1 分钟：回来不锁。
      await background(tester);
      await foreground(tester);
      expect(find.text('小记已锁定'), findsNothing);

      // 再离开一次仍然不锁：守住「验证回来的 resumed 不能误触自动锁定」。
      await background(tester);
      await foreground(tester);
      expect(find.text('小记已锁定'), findsNothing);
    });
  });

  group('无系统锁屏时的兼容', () {
    testWidgets('没有系统锁屏也没有 PIN：先要求设置 PIN，不再静默放行', (
      WidgetTester tester,
    ) async {
      final repository = await openRepository(tester, autoLockSeconds: 0);
      mockSecurityChannel(tester, deviceSecure: false);
      await pumpGate(tester, repository);

      await tester.tap(find.text('解锁'));
      await tester.pump();

      // 关键回归：以前这里会直接解锁，等于应用锁失效。
      expect(find.text('小记已锁定'), findsOneWidget);
      expect(find.text('设备锁屏已关闭，请先设置应用锁 PIN'), findsOneWidget);
      expect(find.text('设置并解锁'), findsOneWidget);

      // 输入 6 位 PIN 并提交。
      for (final String digit in <String>['1', '2', '3', '4', '5', '6']) {
        await tester.tap(find.text(digit));
        await tester.pump();
      }
      await tester.tap(find.text('设置并解锁'));
      // 写 settings.json 是真实文件 IO：fakeAsync 里要交替 runAsync 与 pump，
      // 让真实 IO 完成后再把回调冲进 fake 队列。
      //
      // 用「轮询到界面真的解锁」而不是固定次数：并发跑全量测试时，
      // 写 PIN 的真实 IO 与后续 Keystore 调用都会被拖慢；只等 PIN 落盘不够，
      // 还要等 Gate 把解锁态推到界面。
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
        await tester.pump();
        if (repository.settings.pinHash != null &&
            find.text('小记已锁定').evaluate().isEmpty) {
          break;
        }
      }

      expect(find.text('小记已锁定'), findsNothing);
      expect(repository.settings.pinHash, isNotNull, reason: 'PIN 哈希要落盘');
      expect(repository.settings.pinSalt, isNotNull);
    });

    testWidgets('已有 PIN 时走应用内键盘校验', (WidgetTester tester) async {
      final repository = await openRepository(tester, autoLockSeconds: 0);
      mockSecurityChannel(tester, deviceSecure: false);
      await tester.runAsync(() async {
        await repository.updateSettings(
          repository.settings.copyWith(
            pinHash: 'aGFzaGVkLXBpbg==',
            pinSalt: 'c2FsdHNhbHRzYWx0c2FsdA==',
          ),
        );
      });
      await pumpGate(tester, repository);

      await tester.tap(find.text('解锁'));
      await tester.pump();

      expect(find.text('输入应用锁 PIN'), findsOneWidget);
      expect(find.text('设置并解锁'), findsNothing);
    });
  });

  group('SecurityService 验证状态', () {
    test('authenticate 期间 isAuthenticating 为 true，结束后复位', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final Completer<bool> completer = Completer<bool>();
      messenger.setMockMethodCallHandler(nativeChannel, (
        MethodCall call,
      ) async {
        if (call.method == 'authenticate') {
          return completer.future;
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(nativeChannel, null);
      });

      final Future<bool> running =
          const SecurityService().authenticate(reason: '测试');
      expect(SecurityService.isAuthenticating, isTrue);

      completer.complete(true);
      expect(await running, isTrue);
      expect(SecurityService.isAuthenticating, isFalse);
    });
  });
}
