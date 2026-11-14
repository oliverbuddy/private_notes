import 'dart:async';

import 'package:flutter/services.dart';

/// 是否是可以交给系统打开的外部链接。
bool isExternalLinkUrl(String url) {
  final String lower = url.toLowerCase();
  return lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('mailto:') ||
      lower.startsWith('tel:') ||
      lower.startsWith('sms:');
}

/// 用系统浏览器 / 对应 App 打开外部链接。
///
/// 走原生 MethodChannel（`Intent.ACTION_VIEW`），不引入 url_launcher：
/// 只支持 http(s)、mailto、tel、sms —— 正文里的附件链接（assets/…）
/// 不能交给系统打开，否则会弹「没有应用可执行此操作」。
Future<bool> openExternalLink(String url) async {
  if (!isExternalLinkUrl(url)) {
    return false;
  }
  try {
    final bool? handled = await const MethodChannel('xiaoji/native')
        .invokeMethod<bool>('openUrl', <String, Object?>{'url': url});
    return handled ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    // 纯测试环境没有平台通道：按「未处理」返回，不抛异常打断点击流程。
    return false;
  }
}

/// 忽略打开失败（回调里没有 UI 上下文，失败时保持页面不动）。
void openExternalLinkQuietly(String url) {
  unawaited(openExternalLink(url));
}
