import 'dart:async';
import 'dart:ui' show FlutterView, PlatformDispatcher;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/shortcuts.dart';
import 'data/note_repository.dart';
import 'data/note_store.dart';
import 'home/home_page.dart';
import 'models/note_settings.dart';
import 'platform/platform_features.dart';
import 'security/app_lock_gate.dart';
import 'theme/app_theme.dart';

/// 启动时的逻辑宽度。取不到视图时按「窄屏」处理，保持旧行为。
double _startupWidth() {
  final FlutterView? view =
      WidgetsBinding.instance.platformDispatcher.implicitView;
  if (view == null) {
    return 0;
  }
  return view.physicalSize.width / view.devicePixelRatio;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 窄屏手机锁竖屏：随手记在竖屏下键盘避让/列宽最稳，国内同类也一律竖屏。
  // 平板（宽度 ≥ 600）与桌面不锁：平板横屏才有空间，桌面窗口本来就能拉伸。
  // Android 侧 manifest 已改成 fullUser，这里只在启动时再兜一层。
  if (!PlatformFeatures.isDesktop && _startupWidth() < AppBreakpoints.compact) {
    await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ]);
  }

  // 状态栏透明（edge-to-edge）：部分机型在非 edge-to-edge 模式下会给
  // 状态栏垫一层半透明灰 scrim，观感很脏。全 app 页面顶层都有 SafeArea，
  // 内容不会被状态栏盖住。图标明暗由下方 AnnotatedRegion 跟随主题。
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      // 导航栏透明：页面底色直接铺到手势条后面，不再有系统默认的黑色条。
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  try {
    final store = await NoteStore.create();
    final repository = NoteRepository(store);
    await repository.load();

    // 长按桌面图标选「新建小记」时，冷启动要直接进编辑页，不经过列表。
    listenShortcutEvents();
    final startWithNewNote = await consumeInitialNewNote();

    runApp(XiaojiApp(
      repository: repository,
      startWithNewNote: startWithNewNote,
    ));

    // UI 起来之后再跑：清理超期回收站、当天首份自动备份。
    // 放在首帧之后，避免大备份和首屏抢 IO。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(repository.runMaintenance());
    });
  } catch (error) {
    // 文档目录不可用（极少见，通常是沙箱异常）时也不能白屏。
    runApp(_StartupFailureApp(message: '$error'));
  }
}

class XiaojiApp extends StatefulWidget {
  const XiaojiApp({
    super.key,
    required this.repository,
    this.startWithNewNote = false,
  });

  final NoteRepository repository;
  final bool startWithNewNote;

  @override
  State<XiaojiApp> createState() => _XiaojiAppState();
}

class _XiaojiAppState extends State<XiaojiApp> with WidgetsBindingObserver {
  NoteSettings? _cachedSettings;
  ThemeData? _lightTheme;
  ThemeData? _darkTheme;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回到前台时补一次维护：自动备份改为「距上次 ≥24h」判断，
    // 用户长期不冷启动（手机 App 常驻）也能按节奏备份。
    // runMaintenance 内部有并发锁，且 24 小时内会直接返回。
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.repository.runMaintenance());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.repository,
      builder: (BuildContext context, Widget? child) {
        final settings = widget.repository.settings;

        // 只有设置真的变了才重建 ThemeData。
        // 笔记每次落盘都会 notifyListeners，如果每次都造一个新的 ThemeData，
        // 主题的 InheritedWidget 就会下发变更，正在打字的编辑页会整页重排。
        if (!identical(settings, _cachedSettings)) {
          _cachedSettings = settings;
          _lightTheme = AppTheme.light();
          _darkTheme = AppTheme.dark();
        }

        final darkNow = switch (settings.themeMode) {
          ThemeMode.dark => true,
          ThemeMode.light => false,
          ThemeMode.system =>
            PlatformDispatcher.instance.platformBrightness == Brightness.dark,
        };

        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            // 深色页面用亮图标，浅色页面用暗图标。
            statusBarIconBrightness:
                darkNow ? Brightness.light : Brightness.dark,
            // 导航栏透明 + 图标跟随主题：手势条后面透出的是页面底色，
            // 不再是系统默认的黑色条；三键导航时图标也要跟着换色。
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarDividerColor: Colors.transparent,
            systemNavigationBarIconBrightness:
                darkNow ? Brightness.light : Brightness.dark,
          ),
          child: MaterialApp(
            title: '小记',
            debugShowCheckedModeBanner: false,
            theme: _lightTheme,
            darkTheme: _darkTheme,
            themeMode: settings.themeMode,
            // iOS 手感：回弹滚动 + 无 Android 拉伸光晕；一处配置全站生效。
            scrollBehavior: const AppScrollBehavior(),
            // 中文本地化：系统组件（长按选择菜单的剪切/复制/粘贴、日期选择器、
            // 文本选择手柄气泡等）跟随中文，不再回落英文。
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
            locale: const Locale('zh'),
            // 锁屏挂在 builder 上（而不是 home）：home 只是 Navigator 的首个
            // 路由，编辑页/设置页这些 push 出来的页面会盖在锁屏之上 ——
            // 退后台自动锁定后回来，用户仍能看到当前页面的内容。
            // builder 包住整个 Navigator，锁屏才能盖住所有路由。
            builder: (BuildContext context, Widget? child) => AppLockGate(
              repository: widget.repository,
              child: _DesktopShortcuts(
                child: child ?? const SizedBox.shrink(),
              ),
            ),
            home: HomePage(
              repository: widget.repository,
              startWithNewNote: widget.startWithNewNote,
            ),
          ),
        );
      },
    );
  }
}

/// 桌面端全局快捷键。
///
/// 只做一件手机上没有、桌面上每天都要用的事：⌘N / Ctrl+N 新建。
/// 其余（⌘W 关窗、⌘Q 退出、⌘Z 撤销）由系统与 Flutter 默认行为提供，
/// 不再重复实现 —— 快捷键和系统习惯打架比没有更难用。
class _DesktopShortcuts extends StatelessWidget {
  const _DesktopShortcuts({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!PlatformFeatures.isDesktop) {
      return child;
    }
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyN, meta: true): _NewNoteIntent(),
        SingleActivator(LogicalKeyboardKey.keyN, control: true):
            _NewNoteIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _NewNoteIntent: CallbackAction<_NewNoteIntent>(
            onInvoke: (_) {
              newNoteRequests.value++;
              return null;
            },
          ),
        },
        child: child,
      ),
    );
  }
}

class _NewNoteIntent extends Intent {
  const _NewNoteIntent();
}

class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: AppColors.light.page,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '小记无法启动',
                    style: TextStyle(
                      fontSize: AppFontSize.hint,
                      fontWeight: AppWeight.medium,
                      color: AppColors.light.text,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: AppFontSize.meta,
                      height: 1.6,
                      color: AppColors.light.secondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
