#include "xiaoji_bridge.h"

#include <bcrypt.h>
#include <knownfolders.h>
#include <shellapi.h>
#include <shlobj.h>
#include <wincrypt.h>

#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

// 旧版 SDK 可能没有该常量（Win10 2004 起支持）。
#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

namespace {

// 与 Android BackupBridge / macOS XiaojiBridge 保持一致的格式常量。
constexpr char kEncMagic[] = "XJENC1";
constexpr size_t kEncSaltBytes = 16;
constexpr size_t kEncIvBytes = 12;
constexpr size_t kGcmTagBytes = 16;
constexpr ULONG kEncIterations = 150000;
constexpr ULONG kPinIterations = 120000;
constexpr size_t kPinBytes = 32;

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  int size = ::MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                   static_cast<int>(text.size()), nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring out(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                        out.data(), size);
  return out;
}

std::string WideToUtf8(const std::wstring& text) {
  if (text.empty()) {
    return std::string();
  }
  int size = ::WideCharToMultiByte(CP_UTF8, 0, text.data(),
                                   static_cast<int>(text.size()), nullptr, 0,
                                   nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string out(static_cast<size_t>(size), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                        out.data(), size, nullptr, nullptr);
  return out;
}

std::string Base64Encode(const BYTE* data, size_t length) {
  DWORD chars = 0;
  if (!::CryptBinaryToStringA(data, static_cast<DWORD>(length),
                              CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF,
                              nullptr, &chars)) {
    return std::string();
  }
  std::string out(chars, '\0');
  if (!::CryptBinaryToStringA(data, static_cast<DWORD>(length),
                              CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF,
                              out.data(), &chars)) {
    return std::string();
  }
  // 返回长度含结尾 NUL，去掉。
  while (!out.empty() && (out.back() == '\0' || out.back() == '\r' ||
                          out.back() == '\n')) {
    out.pop_back();
  }
  return out;
}

std::vector<BYTE> Base64Decode(const std::string& text) {
  DWORD size = 0;
  if (!::CryptStringToBinaryA(text.c_str(), static_cast<DWORD>(text.size()),
                              CRYPT_STRING_BASE64, nullptr, &size, nullptr,
                              nullptr)) {
    return std::vector<BYTE>();
  }
  std::vector<BYTE> out(size);
  if (!::CryptStringToBinaryA(text.c_str(), static_cast<DWORD>(text.size()),
                              CRYPT_STRING_BASE64, out.data(), &size, nullptr,
                              nullptr)) {
    return std::vector<BYTE>();
  }
  out.resize(size);
  return out;
}

bool ReadFileBytes(const std::wstring& path, std::vector<BYTE>* out) {
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                              nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  LARGE_INTEGER size = {};
  if (!::GetFileSizeEx(file, &size) || size.QuadPart < 0) {
    ::CloseHandle(file);
    return false;
  }
  out->resize(static_cast<size_t>(size.QuadPart));
  size_t total = 0;
  while (total < out->size()) {
    DWORD read = 0;
    DWORD chunk = static_cast<DWORD>((out->size() - total) > (1u << 20)
                                         ? (1u << 20)
                                         : (out->size() - total));
    if (!::ReadFile(file, out->data() + total, chunk, &read, nullptr)) {
      ::CloseHandle(file);
      return false;
    }
    if (read == 0) {
      break;
    }
    total += read;
  }
  out->resize(total);
  ::CloseHandle(file);
  return true;
}

bool WriteFileBytes(const std::wstring& path, const BYTE* data, size_t length) {
  // 先确保父目录存在：外置备份目录可能是用户新建的空目录。
  size_t slash = path.find_last_of(L"\\/");
  if (slash != std::wstring::npos) {
    std::wstring dir = path.substr(0, slash);
    ::SHCreateDirectoryExW(nullptr, dir.c_str(), nullptr);
  }
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  size_t total = 0;
  while (total < length) {
    DWORD written = 0;
    DWORD chunk = static_cast<DWORD>((length - total) > (1u << 20)
                                         ? (1u << 20)
                                         : (length - total));
    if (!::WriteFile(file, data + total, chunk, &written, nullptr)) {
      ::CloseHandle(file);
      return false;
    }
    total += written;
  }
  ::CloseHandle(file);
  return true;
}

bool RandomBytes(size_t count, std::vector<BYTE>* out) {
  out->assign(count, 0);
  return ::BCryptGenRandom(nullptr, out->data(), static_cast<ULONG>(count),
                           BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0;
}

bool Pbkdf2(const std::string& password, const std::vector<BYTE>& salt,
            LPCWSTR algorithm, ULONG iterations, std::vector<BYTE>* out) {
  BCRYPT_ALG_HANDLE alg = nullptr;
  if (::BCryptOpenAlgorithmProvider(&alg, algorithm, nullptr,
                                    BCRYPT_ALG_HANDLE_HMAC_FLAG) != 0) {
    return false;
  }
  NTSTATUS status = ::BCryptDeriveKeyPBKDF2(
      alg, reinterpret_cast<PUCHAR>(const_cast<char*>(password.data())),
      static_cast<ULONG>(password.size()),
      const_cast<PUCHAR>(salt.data()), static_cast<ULONG>(salt.size()),
      iterations, out->data(), static_cast<ULONG>(out->size()), 0);
  ::BCryptCloseAlgorithmProvider(alg, 0);
  return status == 0;
}

bool AesGcmCrypt(const std::vector<BYTE>& key, const std::vector<BYTE>& iv,
                 const std::vector<BYTE>& input, std::vector<BYTE>* output,
                 std::vector<BYTE>* tag) {
  BCRYPT_ALG_HANDLE alg = nullptr;
  BCRYPT_KEY_HANDLE key_handle = nullptr;
  bool ok = false;

  if (::BCryptOpenAlgorithmProvider(&alg, BCRYPT_AES_ALGORITHM, nullptr, 0) !=
      0) {
    return false;
  }
  if (::BCryptSetProperty(alg, BCRYPT_CHAINING_MODE,
                          reinterpret_cast<PUCHAR>(const_cast<wchar_t*>(
                              BCRYPT_CHAIN_MODE_GCM)),
                          sizeof(BCRYPT_CHAIN_MODE_GCM), 0) != 0) {
    ::BCryptCloseAlgorithmProvider(alg, 0);
    return false;
  }
  if (::BCryptGenerateSymmetricKey(alg, &key_handle, nullptr, 0,
                                   const_cast<PUCHAR>(key.data()),
                                   static_cast<ULONG>(key.size()), 0) != 0) {
    ::BCryptCloseAlgorithmProvider(alg, 0);
    return false;
  }

  BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO auth_info;
  BCRYPT_INIT_AUTH_MODE_INFO(auth_info);
  auth_info.pbNonce = const_cast<PUCHAR>(iv.data());
  auth_info.cbNonce = static_cast<ULONG>(iv.size());
  auth_info.pbTag = tag->data();
  auth_info.cbTag = static_cast<ULONG>(tag->size());

  ULONG written = 0;
  NTSTATUS status = ::BCryptEncrypt(
      key_handle, const_cast<PUCHAR>(input.data()),
      static_cast<ULONG>(input.size()), &auth_info, nullptr, 0,
      output->data(), static_cast<ULONG>(output->size()), &written, 0);
  ok = status == 0;
  output->resize(written);
  ::BCryptDestroyKey(key_handle);
  ::BCryptCloseAlgorithmProvider(alg, 0);
  return ok;
}

bool AesGcmEncrypt(const std::vector<BYTE>& key, const std::vector<BYTE>& iv,
                   const std::vector<BYTE>& plain, std::vector<BYTE>* cipher,
                   std::vector<BYTE>* tag) {
  cipher->assign(plain.size(), 0);
  tag->assign(kGcmTagBytes, 0);
  return AesGcmCrypt(key, iv, plain, cipher, tag);
}

bool AesGcmDecrypt(const std::vector<BYTE>& key, const std::vector<BYTE>& iv,
                   const std::vector<BYTE>& cipher,
                   const std::vector<BYTE>& tag, std::vector<BYTE>* plain) {
  plain->assign(cipher.size(), 0);
  std::vector<BYTE> tag_copy = tag;
  BCRYPT_ALG_HANDLE alg = nullptr;
  BCRYPT_KEY_HANDLE key_handle = nullptr;
  bool ok = false;
  if (::BCryptOpenAlgorithmProvider(&alg, BCRYPT_AES_ALGORITHM, nullptr, 0) !=
      0) {
    return false;
  }
  if (::BCryptSetProperty(alg, BCRYPT_CHAINING_MODE,
                          reinterpret_cast<PUCHAR>(const_cast<wchar_t*>(
                              BCRYPT_CHAIN_MODE_GCM)),
                          sizeof(BCRYPT_CHAIN_MODE_GCM), 0) != 0) {
    ::BCryptCloseAlgorithmProvider(alg, 0);
    return false;
  }
  if (::BCryptGenerateSymmetricKey(alg, &key_handle, nullptr, 0,
                                   const_cast<PUCHAR>(key.data()),
                                   static_cast<ULONG>(key.size()), 0) != 0) {
    ::BCryptCloseAlgorithmProvider(alg, 0);
    return false;
  }
  BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO auth_info;
  BCRYPT_INIT_AUTH_MODE_INFO(auth_info);
  auth_info.pbNonce = const_cast<PUCHAR>(iv.data());
  auth_info.cbNonce = static_cast<ULONG>(iv.size());
  auth_info.pbTag = tag_copy.data();
  auth_info.cbTag = static_cast<ULONG>(tag_copy.size());

  ULONG written = 0;
  NTSTATUS status = ::BCryptDecrypt(
      key_handle, const_cast<PUCHAR>(cipher.data()),
      static_cast<ULONG>(cipher.size()), &auth_info, nullptr, 0,
      plain->data(), static_cast<ULONG>(plain->size()), &written, 0);
  ok = status == 0;
  plain->resize(written);
  ::BCryptDestroyKey(key_handle);
  ::BCryptCloseAlgorithmProvider(alg, 0);
  return ok;
}

const flutter::EncodableValue* FindArg(const flutter::EncodableMap& args,
                                       const char* key) {
  auto it = args.find(flutter::EncodableValue(std::string(key)));
  return it == args.end() ? nullptr : &it->second;
}

std::string GetStringArg(const flutter::EncodableMap& args, const char* key) {
  const flutter::EncodableValue* value = FindArg(args, key);
  if (value == nullptr) {
    return std::string();
  }
  const std::string* text = std::get_if<std::string>(value);
  return text == nullptr ? std::string() : *text;
}

bool GetBoolArg(const flutter::EncodableMap& args, const char* key,
                bool fallback) {
  const flutter::EncodableValue* value = FindArg(args, key);
  if (value == nullptr) {
    return fallback;
  }
  const bool* flag = std::get_if<bool>(value);
  return flag == nullptr ? fallback : *flag;
}

// DPAPI：用当前 Windows 账户派生密钥，同一台机器同一账户才能解开。
std::string SealWithDpapi(const std::string& plain) {
  DATA_BLOB input = {static_cast<DWORD>(plain.size()),
                     reinterpret_cast<BYTE*>(const_cast<char*>(plain.data()))};
  std::string entropy_text = "xiaoji-seal-v1";
  DATA_BLOB entropy = {static_cast<DWORD>(entropy_text.size()),
                       reinterpret_cast<BYTE*>(entropy_text.data())};
  DATA_BLOB output = {};
  if (!::CryptProtectData(&input, L"xiaoji", &entropy, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    return std::string();
  }
  std::string encoded = Base64Encode(output.pbData, output.cbData);
  ::LocalFree(output.pbData);
  return encoded;
}

bool OpenWithDpapi(const std::string& encoded, std::string* plain) {
  std::vector<BYTE> raw = Base64Decode(encoded);
  if (raw.empty()) {
    return false;
  }
  std::string entropy_text = "xiaoji-seal-v1";
  DATA_BLOB input = {static_cast<DWORD>(raw.size()), raw.data()};
  DATA_BLOB entropy = {static_cast<DWORD>(entropy_text.size()),
                       reinterpret_cast<BYTE*>(entropy_text.data())};
  DATA_BLOB output = {};
  if (!::CryptUnprotectData(&input, nullptr, &entropy, nullptr, nullptr,
                            CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    return false;
  }
  plain->assign(reinterpret_cast<char*>(output.pbData), output.cbData);
  ::LocalFree(output.pbData);
  return true;
}

std::wstring PicturesDirectory() {
  PWSTR path = nullptr;
  if (FAILED(::SHGetKnownFolderPath(FOLDERID_Pictures, 0, nullptr, &path))) {
    return std::wstring();
  }
  std::wstring result(path);
  ::CoTaskMemFree(path);
  return result;
}

std::wstring UniqueTargetPath(const std::wstring& dir,
                              const std::wstring& file_name) {
  std::wstring base = file_name;
  std::wstring ext;
  size_t dot = file_name.find_last_of(L'.');
  if (dot != std::wstring::npos) {
    base = file_name.substr(0, dot);
    ext = file_name.substr(dot);
  }
  std::wstring candidate = dir + L"\\" + file_name;
  int index = 2;
  while (::GetFileAttributesW(candidate.c_str()) != INVALID_FILE_ATTRIBUTES) {
    candidate = dir + L"\\" + base + L"-" + std::to_wstring(index) + ext;
    ++index;
  }
  return candidate;
}

}  // namespace

XiaojiBridge::XiaojiBridge(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "xiaoji/native", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

XiaojiBridge::~XiaojiBridge() = default;

void XiaojiBridge::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args_ptr =
      std::get_if<flutter::EncodableMap>(call.arguments());
  const flutter::EncodableMap args =
      args_ptr == nullptr ? flutter::EncodableMap() : *args_ptr;
  const std::string& method = call.method_name();

  if (method == "isDeviceSecure" || method == "authenticate") {
    // 未接入 Windows Hello：Dart 侧会自动回退到应用内 PIN。
    result->Success(flutter::EncodableValue(false));
    return;
  }

  if (method == "randomSalt") {
    std::vector<BYTE> salt;
    if (!RandomBytes(16, &salt)) {
      result->Success(flutter::EncodableValue());
      return;
    }
    result->Success(flutter::EncodableValue(Base64Encode(salt.data(), salt.size())));
    return;
  }

  if (method == "hashPin") {
    const std::string pin = GetStringArg(args, "pin");
    const std::vector<BYTE> salt = Base64Decode(GetStringArg(args, "salt"));
    if (salt.empty()) {
      result->Error("hash_failed", "盐格式不正确");
      return;
    }
    std::vector<BYTE> derived(kPinBytes);
    if (!Pbkdf2(pin, salt, BCRYPT_SHA256_ALGORITHM, kPinIterations, &derived)) {
      result->Error("hash_failed", "PIN 处理失败");
      return;
    }
    result->Success(flutter::EncodableValue(Base64Encode(derived.data(), derived.size())));
    return;
  }

  if (method == "sealText") {
    const std::string sealed = SealWithDpapi(GetStringArg(args, "text"));
    if (sealed.empty()) {
      result->Error("seal_failed", "加密失败");
      return;
    }
    result->Success(flutter::EncodableValue(sealed));
    return;
  }

  if (method == "openText") {
    std::string plain;
    if (!OpenWithDpapi(GetStringArg(args, "payload"), &plain)) {
      result->Error("open_failed", "解密失败");
      return;
    }
    result->Success(flutter::EncodableValue(plain));
    return;
  }

  if (method == "setSecureScreen") {
    const bool enabled = GetBoolArg(args, "enabled", false);
    if (window_ != nullptr) {
      // Win10 2004+ 支持真正「从截屏中排除」；老系统退到黑屏模式。
      DWORD affinity = enabled ? WDA_EXCLUDEFROMCAPTURE : WDA_NONE;
      if (!::SetWindowDisplayAffinity(window_, affinity) && enabled) {
        ::SetWindowDisplayAffinity(window_, WDA_MONITOR);
      }
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "encryptFile") {
    const std::string password = GetStringArg(args, "password");
    if (password.size() < 6) {
      result->Error("weak_password", "备份口令至少 6 位");
      return;
    }
    std::vector<BYTE> plain;
    if (!ReadFileBytes(Utf8ToWide(GetStringArg(args, "sourcePath")), &plain)) {
      result->Error("missing_source", "待加密的备份不存在");
      return;
    }
    std::vector<BYTE> salt;
    std::vector<BYTE> iv;
    if (!RandomBytes(kEncSaltBytes, &salt) ||
        !RandomBytes(kEncIvBytes, &iv)) {
      result->Error("encrypt_failed", "无法生成随机数");
      return;
    }
    std::vector<BYTE> key(32);
    if (!Pbkdf2(password, salt, BCRYPT_SHA1_ALGORITHM, kEncIterations, &key)) {
      result->Error("encrypt_failed", "密钥派生失败");
      return;
    }
    std::vector<BYTE> cipher;
    std::vector<BYTE> tag;
    if (!AesGcmEncrypt(key, iv, plain, &cipher, &tag)) {
      result->Error("encrypt_failed", "加密失败");
      return;
    }
    std::vector<BYTE> output;
    output.insert(output.end(), kEncMagic, kEncMagic + 6);
    output.insert(output.end(), salt.begin(), salt.end());
    output.insert(output.end(), iv.begin(), iv.end());
    output.insert(output.end(), cipher.begin(), cipher.end());
    output.insert(output.end(), tag.begin(), tag.end());
    const std::wstring target = Utf8ToWide(GetStringArg(args, "targetPath"));
    if (!WriteFileBytes(target, output.data(), output.size())) {
      result->Error("encrypt_failed", "写入加密备份失败");
      return;
    }
    result->Success(flutter::EncodableValue(WideToUtf8(target)));
    return;
  }

  if (method == "decryptFile") {
    std::vector<BYTE> raw;
    if (!ReadFileBytes(Utf8ToWide(GetStringArg(args, "sourcePath")), &raw)) {
      result->Error("missing_source", "备份文件不存在");
      return;
    }
    const size_t header = 6 + kEncSaltBytes + kEncIvBytes;
    if (raw.size() <= header + kGcmTagBytes ||
        std::string(reinterpret_cast<char*>(raw.data()), 6) != kEncMagic) {
      result->Error("not_encrypted", "不是加密备份文件");
      return;
    }
    const std::vector<BYTE> salt(raw.begin() + 6,
                                 raw.begin() + 6 + kEncSaltBytes);
    const std::vector<BYTE> iv(raw.begin() + 6 + kEncSaltBytes,
                               raw.begin() + header);
    const std::vector<BYTE> cipher(raw.begin() + header,
                                   raw.end() - kGcmTagBytes);
    const std::vector<BYTE> tag(raw.end() - kGcmTagBytes, raw.end());

    std::vector<BYTE> key(32);
    std::vector<BYTE> plain;
    if (!Pbkdf2(GetStringArg(args, "password"), salt, BCRYPT_SHA1_ALGORITHM,
                kEncIterations, &key) ||
        !AesGcmDecrypt(key, iv, cipher, tag, &plain)) {
      result->Error("bad_password", "口令不正确或文件已损坏");
      return;
    }
    const std::wstring target = Utf8ToWide(GetStringArg(args, "targetPath"));
    if (!WriteFileBytes(target, plain.data(), plain.size())) {
      result->Error("decrypt_failed", "写入解密结果失败");
      return;
    }
    result->Success(flutter::EncodableValue(WideToUtf8(target)));
    return;
  }

  if (method == "openUrl") {
    const std::wstring url = Utf8ToWide(GetStringArg(args, "url"));
    HINSTANCE handle = ::ShellExecuteW(nullptr, L"open", url.c_str(), nullptr,
                                       nullptr, SW_SHOWNORMAL);
    result->Success(
        flutter::EncodableValue(reinterpret_cast<intptr_t>(handle) > 32));
    return;
  }

  if (method == "saveImage") {
    const std::wstring source = Utf8ToWide(GetStringArg(args, "path"));
    const std::wstring pictures = PicturesDirectory();
    if (pictures.empty()) {
      flutter::EncodableMap payload;
      payload[flutter::EncodableValue("savedToGallery")] =
          flutter::EncodableValue(false);
      result->Success(flutter::EncodableValue(payload));
      return;
    }
    const std::wstring dir = pictures + L"\\\u5C0F\u8BB0";
    ::SHCreateDirectoryExW(nullptr, dir.c_str(), nullptr);
    std::wstring name = source.substr(source.find_last_of(L"\\/") + 1);
    const std::wstring target = UniqueTargetPath(dir, name);
    const bool copied = ::CopyFileW(source.c_str(), target.c_str(), FALSE) != 0;
    flutter::EncodableMap payload;
    payload[flutter::EncodableValue("savedToGallery")] =
        flutter::EncodableValue(copied);
    result->Success(flutter::EncodableValue(payload));
    return;
  }

  if (method == "shareImage") {
    // 桌面端没有系统分享面板：退化成「另存为」。
    const std::wstring source = Utf8ToWide(GetStringArg(args, "path"));
    wchar_t buffer[MAX_PATH] = {};
    std::wstring file_name = source.substr(source.find_last_of(L"\\/") + 1);
    if (file_name.size() >= MAX_PATH) {
      file_name.resize(MAX_PATH - 1);
    }
    std::copy(file_name.begin(), file_name.end(), buffer);
    OPENFILENAMEW dialog = {};
    dialog.lStructSize = sizeof(dialog);
    dialog.hwndOwner = window_;
    dialog.lpstrFile = buffer;
    dialog.nMaxFile = MAX_PATH;
    dialog.lpstrFilter = L"\u56FE\u7247\0*.png;*.jpg;*.jpeg\0\0";
    dialog.Flags = OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST;
    if (!::GetSaveFileNameW(&dialog)) {
      result->Success(flutter::EncodableValue());
      return;
    }
    ::CopyFileW(source.c_str(), buffer, FALSE);
    result->Success(flutter::EncodableValue());
    return;
  }

  // 移动端专属能力（分享导入、桌面小组件、SAF 目录等）不实现，
  // Dart 侧会按 MissingPluginException 走桌面回退。
  result->NotImplemented();
}
