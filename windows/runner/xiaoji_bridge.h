#ifndef RUNNER_XIAOJI_BRIDGE_H_
#define RUNNER_XIAOJI_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <string>
#include <vector>

// Windows 侧的 `xiaoji/native` 通道实现。
//
// 与 Android 的 SecurityBridge / BackupBridge 语义一致：
//  - 正文与备份口令用 DPAPI 封存（按 Windows 用户账户隔离，别人拷走文件也解不开）；
//  - 备份包 `XJENC1` 用 CNG(BCrypt) 的 AES-256-GCM，PBKDF2-HMAC-SHA1 派生，
//    与安卓/macOS 互通；
//  - 截屏保护用 SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)。
//
// 系统级身份验证（Windows Hello）暂不接入：Dart 侧在 isDeviceSecure/authenticate
// 返回 false 时会自动回退到应用内 PIN，功能不缺失。
class XiaojiBridge {
 public:
  XiaojiBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~XiaojiBridge();

  XiaojiBridge(const XiaojiBridge&) = delete;
  XiaojiBridge& operator=(const XiaojiBridge&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_XIAOJI_BRIDGE_H_
