import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app/shortcuts.dart';
import 'data/note_repository.dart';
import 'data/note_store.dart';
import 'home/home_page.dart';
import 'models/note_settings.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 锁定竖屏：这是手机端的随手记工具，横屏下正文列宽/键盘避让都没有
  // 适配过，跟着传感器转会直接把布局打散。国内同类 App 也一律竖屏。
  // Android 侧同时在 manifest 里声明 screenOrientation="portrait"，
  // 两侧都锁，避免启动瞬间先转一次。
  await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
    DeviceOrientation.portraitUp,
  ]);

  // 状态栏透明（edge-to-edge）：部分机型在非 edge-to-edge 模式下会给
  // 状态栏垫一层半透明灰 scrim，观感很脏。全 app 页面顶层都有 SafeArea，
  // 内容不会被状态栏盖住。图标明暗由下方 AnnotatedRegion 跟随主题。
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(statusBarColor: Colors.transparent),
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

class _XiaojiAppState extends State<XiaojiApp> {
  NoteSettings? _cachedSettings;
  ThemeData? _lightTheme;
  ThemeData? _darkTheme;

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
          ),
          child: MaterialApp(
          title: '小记',
          debugShowCheckedModeBanner: false,
          theme: _lightTheme,
          darkTheme: _darkTheme,
          themeMode: settings.themeMode,
          // 中文本地化：系统组件（长按选择菜单的剪切/复制/粘贴、日期选择器、
          // 文本选择手柄气泡等）跟随中文，不再回落英文。
          localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
          locale: const Locale('zh'),
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
                      fontSize: 15,
                      fontWeight: AppWeight.medium,
                      color: AppColors.light.text,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
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
