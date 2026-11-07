import 'package:flutter/material.dart';

import '../models/note_settings.dart';
import '../theme/app_theme.dart';
import '../ui/show_sheet.dart';
import '../ui/snack.dart';
import 'pin_pad.dart';
import 'security_service.dart';

const SecurityService kSecurity = SecurityService();

/// 验证身份：设备有安全锁屏走系统凭证，否则用已设置的备用 PIN。
///
/// 用于「关闭应用锁」「打开/取消锁定某条笔记」这类敏感动作。
Future<bool> verifyIdentity(
  BuildContext context, {
  required NoteSettings settings,
  required String reason,
}) async {
  if (await kSecurity.isDeviceSecure()) {
    return kSecurity.authenticate(reason: reason);
  }
  final String? salt = settings.pinSalt;
  final String? hash = settings.pinHash;
  if (salt == null || hash == null) {
    // 没有任何验证方式：放行，避免把用户锁在自己的数据外。
    return true;
  }
  if (!context.mounted) {
    return false;
  }
  final String? pin = await promptPinSheet(context, title: '输入应用锁 PIN');
  if (pin == null) {
    return false;
  }
  final String input = await kSecurity.hashPin(pin: pin, salt: salt);
  if (input != hash) {
    // PIN 输错时给明确反馈：调用方失败后通常直接退出当前动作，
    // 没有这句话用户会以为是「点了没反应」。
    if (context.mounted) {
      showSnack(context, message: 'PIN 不正确');
    }
    return false;
  }
  return true;
}

/// 通用 PIN 输入弹层（4–6 位数字）。
///
/// 用 [PinEntry] 的应用内数字键盘，不接系统 IME：`TextField` 的 composing
/// 状态在安卓上会和程序状态打架，实测出现「退格后重输一位却补满 6 位」。
Future<String?> promptPinSheet(
  BuildContext context, {
  required String title,
}) async {
  return showXiaojiSheet<String>(
    context: context,
    builder: (BuildContext sheetContext) {
      final AppColors colors = AppColors.of(sheetContext);
      String pin = '';
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setSheetState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: AppText.sheetTitle.copyWith(color: colors.text),
                  ),
                  const SizedBox(height: 18),
                  PinEntry(
                    value: pin,
                    onChanged: (String next) {
                      setSheetState(() => pin = next);
                    },
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    height: AppSize.button,
                    child: FilledButton(
                      onPressed: pin.length >= 4
                          ? () => Navigator.of(sheetContext).pop(pin)
                          : null,
                      child: const Text('确定'),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}
