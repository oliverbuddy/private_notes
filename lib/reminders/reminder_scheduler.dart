import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// 一条待调度的提醒。
///
/// 只带「展示所需」的信息，不依赖 Note 模型：未来 PC/iOS 端的调度适配器
/// 可以复用同一个结构，不需要 import 数据层。
@immutable
class ReminderItem {
  const ReminderItem({
    required this.noteId,
    required this.at,
    required this.title,
    required this.body,
  });

  final String noteId;
  final DateTime at;
  final String title;
  final String body;
}

/// 提醒权限申请结果。
enum ReminderPermission {
  /// 通知权限与精确闹钟都可用。
  granted,

  /// 通知可用，但精确闹钟被拒（提醒可能延迟几分钟）。
  exactDenied,

  /// 通知权限被拒，提醒不会显示。
  denied,
}

/// 跨端提醒调度接口。
///
/// 业务层只依赖这个接口；Android/iOS/macOS/Windows/Linux 的差异由具体
/// 适配器承担。当前实现走 flutter_local_notifications，它在 Android 上
/// 使用 AlarmManager + 开机广播，在 iOS/macOS/Windows 上使用系统通知中心，
/// 后续新增平台只需要补一个适配器，不改上方业务代码。
abstract class ReminderScheduler {
  Future<void> initialize({required void Function(String noteId) onOpenNote});

  Future<ReminderPermission> ensurePermissions();

  /// 全量对账：取消所有已排程的提醒，再按 [items] 重新排程（幂等）。
  Future<void> sync(List<ReminderItem> items);

  /// 冷启动时读取「是否由通知点击启动」，返回对应笔记 id。
  Future<String?> consumeLaunchNoteId();
}

/// 基于 flutter_local_notifications 的实现（Android / iOS / macOS / Windows / Linux）。
class LocalNotificationsReminderScheduler implements ReminderScheduler {
  LocalNotificationsReminderScheduler();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _ready = false;
  bool _exactAllowed = true;
  Future<void>? _initializing;

  static const String _channelId = 'xiaoji_reminders';
  static const String _channelName = '小记提醒';
  static const String _channelDescription = '到点提醒你处理小记';
  static const String _smallIcon = 'ic_widget_pen';

  @override
  Future<void> initialize({
    required void Function(String noteId) onOpenNote,
  }) {
    return _initializing ??= _doInitialize(onOpenNote);
  }

  Future<void> _doInitialize(void Function(String noteId) onOpenNote) async {
    try {
      tz_data.initializeTimeZones();
      try {
        final TimezoneInfo info =
            await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(info.identifier));
      } catch (_) {
        // 拿不到系统时区名时退回 UTC：提醒时间会偏，但不至于初始化失败。
        tz.setLocalLocation(tz.getLocation('UTC'));
      }

      const InitializationSettings settings = InitializationSettings(
        android: AndroidInitializationSettings(_smallIcon),
        iOS: DarwinInitializationSettings(),
        macOS: DarwinInitializationSettings(),
      );
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          final String? payload = response.payload;
          if (payload != null && payload.isNotEmpty) {
            onOpenNote(payload);
          }
        },
      );
      _ready = true;
    } on MissingPluginException catch (error) {
      // 测试环境 / 未支持的平台：调度降级为无操作，不影响笔记本身。
      debugPrint('提醒调度不可用：$error');
    } catch (error, stack) {
      debugPrint('提醒初始化失败：$error\n$stack');
    }
  }

  @override
  Future<ReminderPermission> ensurePermissions() async {
    if (!_ready) {
      return ReminderPermission.denied;
    }
    try {
      if (Platform.isAndroid) {
        final android = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        final bool granted =
            await android?.requestNotificationsPermission() ?? true;
        if (!granted) {
          return ReminderPermission.denied;
        }
        final bool exact =
            await android?.requestExactAlarmsPermission() ?? true;
        _exactAllowed = exact;
        return exact
            ? ReminderPermission.granted
            : ReminderPermission.exactDenied;
      }
      if (Platform.isIOS) {
        final ios = _plugin.resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
        final bool? granted = await ios?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
        return (granted ?? true)
            ? ReminderPermission.granted
            : ReminderPermission.denied;
      }
      if (Platform.isMacOS) {
        final macos = _plugin.resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin>();
        final bool? granted = await macos?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
        return (granted ?? true)
            ? ReminderPermission.granted
            : ReminderPermission.denied;
      }
      // Windows / Linux：系统通知无需运行时权限。
      return ReminderPermission.granted;
    } catch (error) {
      debugPrint('提醒权限申请失败：$error');
      return ReminderPermission.denied;
    }
  }

  @override
  Future<void> sync(List<ReminderItem> items) async {
    if (!_ready) {
      return;
    }
    try {
      await _plugin.cancelAll();
      final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
      for (final ReminderItem item in items) {
        final tz.TZDateTime at = tz.TZDateTime.from(item.at, tz.local);
        if (!at.isAfter(now)) {
          continue;
        }
        await _plugin.zonedSchedule(
          id: _stableId(item.noteId),
          title: item.title,
          body: item.body,
          scheduledDate: at,
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              _channelName,
              channelDescription: _channelDescription,
              importance: Importance.high,
              priority: Priority.high,
              category: AndroidNotificationCategory.reminder,
              icon: _smallIcon,
            ),
            iOS: DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
            ),
            macOS: DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
            ),
          ),
          androidScheduleMode: _exactAllowed
              ? AndroidScheduleMode.exactAllowWhileIdle
              : AndroidScheduleMode.inexactAllowWhileIdle,
          payload: item.noteId,
        );
      }
    } catch (error, stack) {
      debugPrint('提醒排程失败：$error\n$stack');
    }
  }

  @override
  Future<String?> consumeLaunchNoteId() async {
    if (!_ready) {
      return null;
    }
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp != true) {
        return null;
      }
      final String? payload = details?.notificationResponse?.payload;
      return (payload != null && payload.isNotEmpty) ? payload : null;
    } catch (error) {
      debugPrint('读取通知启动信息失败：$error');
      return null;
    }
  }

  /// 稳定的通知 id：同一个 noteId 每次启动都算出同一个值，重复排程是覆盖。
  static int _stableId(String noteId) {
    var hash = 0x811c9dc5;
    for (final int unit in noteId.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return hash == 0 ? 1 : hash;
  }
}
