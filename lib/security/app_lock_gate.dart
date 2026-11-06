import 'package:flutter/material.dart';

import '../data/note_repository.dart';
import '../theme/app_theme.dart';
import 'pin_pad.dart';
import 'security_service.dart';

/// 应用锁闸门：启用后冷启动 / 后台超时回来先显示锁屏。
///
/// 解锁优先走系统凭证（设备 PIN/图案/指纹），设备没有安全锁屏时回退到
/// 应用内 6 位 PIN。锁屏期间内容不渲染 + FLAG_SECURE，避免多任务预览
/// 和截屏把正文带出去。
class AppLockGate extends StatefulWidget {
  const AppLockGate({
    super.key,
    required this.repository,
    required this.child,
  });

  final NoteRepository repository;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate>
    with WidgetsBindingObserver {
  static const SecurityService _security = SecurityService();

  late bool _locked = widget.repository.settings.lockEnabled;
  DateTime? _backgroundedAt;
  bool _authenticating = false;

  /// 设备没有系统安全锁屏时，锁屏页内联展示 PIN 输入。
  ///
  /// 不能用 `showXiaojiSheet`：闸门挂在 `MaterialApp.builder` 上，
  /// 位于 Navigator 之上，`Navigator.of(context)` 取不到路由 —— 之前
  /// 弹底部 PIN 层会直接抛出空指针。所以这里用 [PinEntry] 自绘键盘。
  bool _pinMode = false;
  String _pinDigits = '';
  String? _pinError;

  bool get _enabled => widget.repository.settings.lockEnabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.repository.addListener(_onSettingsChanged);
    _applySecureFlag();
  }

  @override
  void dispose() {
    widget.repository.removeListener(_onSettingsChanged);
    WidgetsBinding.instance.removeObserver(this);
    if (_locked) {
      // 页面销毁时注销截屏保护（例如被系统回收后重建）。
      _security.setSecureHolder(_secureKey, false).catchError((Object _) {});
    }
    super.dispose();
  }

  /// 应用锁在截屏保护持有者里的 key。
  static const String _secureKey = 'applock';

  void _onSettingsChanged() {
    if (!_enabled && _locked) {
      // 用户在设置里关掉了应用锁：立即放行。
      setState(() => _locked = false);
      _applySecureFlag();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_enabled) {
      return;
    }
    // 系统凭证页是我们自己拉起的另一个 Activity：拉起时 paused、验证结束
    // 后 resumed，都发生在验证流程内部。若按普通「离开 App」处理，自动锁定
    // 设为「立即」时验证刚通过就又会被锁上 —— 用户看到的就是永远解不开。
    if (SecurityService.isAuthenticating) {
      return;
    }
    // 只认 paused：hidden 在「从别的 Activity 返回」时也会触发（顺序是
    // paused → hidden → inactive → resumed），系统验证页一关就会先来一次
    // hidden，自动锁定设为「立即」时又会重新上锁。paused 已经足够表达
    // 「App 离开前台」。
    if (state == AppLifecycleState.paused) {
      _backgroundedAt = DateTime.now();
      if (widget.repository.settings.autoLockSeconds == 0) {
        // 「立即锁定」：一退到后台就锁，回来必验证。
        if (!_locked) {
          setState(() => _locked = true);
          _applySecureFlag();
        }
      }
    } else if (state == AppLifecycleState.resumed) {
      final DateTime? leftAt = _backgroundedAt;
      _backgroundedAt = null;
      if (leftAt == null || _locked) {
        return;
      }
      final int timeout = widget.repository.settings.autoLockSeconds;
      if (DateTime.now().difference(leftAt).inSeconds >= timeout) {
        setState(() => _locked = true);
        _applySecureFlag();
      }
    }
  }

  void _applySecureFlag() {
    final bool shouldSecure = _locked && widget.repository.settings.secureScreen;
    // 失败不影响锁屏本身（部分 ROM 可能不支持）。
    _security
        .setSecureHolder(_secureKey, shouldSecure)
        .catchError((Object _) {});
  }

  Future<void> _unlock() async {
    if (_authenticating) {
      return;
    }
    setState(() => _authenticating = true);
    try {
      final bool deviceSecure = await _security.isDeviceSecure();
      if (!mounted) {
        return;
      }
      if (deviceSecure) {
        final bool ok =
            await _security.authenticate(reason: '验证身份后查看小记');
        if (!mounted) {
          return;
        }
        if (ok) {
          _onUnlocked();
        }
      } else if (widget.repository.settings.pinHash != null) {
        // 没有系统锁屏：切到锁屏页内联的 PIN 键盘。
        setState(() {
          _pinMode = true;
          _pinDigits = '';
          _pinError = null;
        });
      } else {
        // 没有任何可用验证方式：放行，避免把用户锁死在自己的数据外。
        _onUnlocked();
      }
    } catch (error) {
      if (mounted) {
        setState(() => _pinError = '验证失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _authenticating = false);
      }
    }
  }

  void _onUnlocked() {
    setState(() {
      _locked = false;
      _pinMode = false;
      _pinDigits = '';
      _pinError = null;
    });
    // 验证成功后必须清掉离场时间：系统凭证页关闭会紧接着来一次 resumed，
    // 残留的 _backgroundedAt 会让「立即锁定 / 1 分钟」判定成立而重新上锁。
    _backgroundedAt = null;
    _applySecureFlag();
  }

  /// 校验锁屏页里输入的 PIN。
  Future<void> _submitPin() async {
    if (_pinDigits.length < 4) {
      setState(() => _pinError = '请输入 4–6 位 PIN');
      return;
    }
    final settings = widget.repository.settings;
    final String? salt = settings.pinSalt;
    final String? hash = settings.pinHash;
    if (salt == null || hash == null) {
      _onUnlocked();
      return;
    }
    if (_authenticating) {
      return;
    }
    setState(() {
      _authenticating = true;
      _pinError = null;
    });
    try {
      final String input =
          await _security.hashPin(pin: _pinDigits, salt: salt);
      if (!mounted) {
        return;
      }
      if (input == hash) {
        _onUnlocked();
      } else {
        setState(() {
          _pinError = 'PIN 不正确';
          _pinDigits = '';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _pinError = '验证失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _authenticating = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled) {
      return widget.child;
    }
    final AppColors colors = AppColors.of(context);
    // 用 Stack 盖住整个 Navigator，而不是把 child 从树上摘掉：
    // 摘掉会销毁 Navigator 状态（锁定时正在编辑的页面会被关掉）。
    // 锁定时 child 以 Visibility 隐藏（不绘制、不响应点击），解锁后原样回来。
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Visibility(
          visible: !_locked,
          maintainState: true,
          maintainAnimation: true,
          maintainSize: true,
          child: widget.child,
        ),
        if (_locked)
          Scaffold(
            backgroundColor: colors.page,
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.lock_outline, size: 44, color: colors.secondary),
                      const SizedBox(height: 18),
                      Text(
                        '小记已锁定',
                        style: TextStyle(
                          fontSize: 20,
                          height: 1.2,
                          fontWeight: AppWeight.medium,
                          color: colors.text,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _pinMode ? '输入应用锁 PIN' : '验证身份后查看你的笔记',
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.6,
                          color: colors.tertiary,
                        ),
                      ),
                      const SizedBox(height: 28),
                      if (_pinMode)
                        PinEntry(
                          value: _pinDigits,
                          error: _pinError,
                          onChanged: (String next) {
                            setState(() {
                              _pinDigits = next;
                              _pinError = null;
                            });
                          },
                        )
                      else
                        const SizedBox.shrink(),
                      if (_pinMode) const SizedBox(height: 16),
                      SizedBox(
                        width: 200,
                        height: 48,
                        child: FilledButton(
                          onPressed: _authenticating
                              ? null
                              : (_pinMode ? _submitPin : _unlock),
                          child: _authenticating
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('解锁'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
