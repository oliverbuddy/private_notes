import Cocoa
import CommonCrypto
import CryptoKit
import FlutterMacOS
import LocalAuthentication
import Security

/// macOS 侧的 `xiaoji/native` 通道实现。
///
/// 与 Android 的 SecurityBridge / BackupBridge 一一对应，语义保持一致：
///  - 身份验证走系统凭证（触控 ID / 登录密码）；
///  - 正文与备份口令用 Keychain 里的 256 位密钥做 AES-GCM；
///  - 备份包格式 `XJENC1` + 盐 + IV + GCM 密文，与安卓互通（PBKDF2-HMAC-SHA1）。
///
/// 不引入第三方依赖：加解密用系统 CryptoKit，PBKDF2 用 CommonCrypto，
/// 密钥存 Keychain（不出设备，也不进设置文件）。
final class XiaojiBridge {
  private let keychainService = "com.xiaoji.xiaoji"
  private let keychainAccount = "note-key-v1"

  /// XJENC1 格式常量：必须与 Android BackupBridge 完全一致。
  private static let encMagic = "XJENC1"
  private static let encSaltBytes = 16
  private static let encIvBytes = 12
  private static let encIterations: UInt32 = 150_000

  /// PIN 哈希参数：只需本机校验一致，取 Android 10+ 的同款参数。
  private static let pinIterations: UInt32 = 120_000
  private static let pinBytes = 32

  private var channel: FlutterMethodChannel?

  init(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "xiaoji/native", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "isDeviceSecure":
      result(isDeviceSecure())
    case "authenticate":
      authenticate(reason: args["reason"] as? String ?? "验证身份后继续", result: result)
    case "randomSalt":
      result(randomSaltBase64())
    case "hashPin":
      hashPin(pin: args["pin"] as? String ?? "",
              salt: args["salt"] as? String ?? "",
              result: result)
    case "sealText":
      sealText(plain: args["text"] as? String ?? "", result: result)
    case "openText":
      openText(payload: args["payload"] as? String ?? "", result: result)
    case "setSecureScreen":
      setSecureScreen(enabled: args["enabled"] as? Bool ?? false, result: result)
    case "encryptFile":
      encryptFile(source: args["sourcePath"] as? String ?? "",
                  target: args["targetPath"] as? String ?? "",
                  password: args["password"] as? String ?? "",
                  result: result)
    case "decryptFile":
      decryptFile(source: args["sourcePath"] as? String ?? "",
                  target: args["targetPath"] as? String ?? "",
                  password: args["password"] as? String ?? "",
                  result: result)
    case "openUrl":
      openUrl(args["url"] as? String ?? "", result: result)
    case "saveImage":
      saveImage(path: args["path"] as? String ?? "", result: result)
    case "shareImage":
      shareImage(path: args["path"] as? String ?? "", result: result)
    default:
      // 其余（分享导入、桌面小组件、SAF 目录等）是移动端专属能力，
      // Dart 侧已按 MissingPluginException 回退，这里明确不实现。
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - 身份验证

  /// 系统是否设置了登录密码（macOS 上等价于「设备是否安全」）。
  private func isDeviceSecure() -> Bool {
    let context = LAContext()
    var error: NSError?
    return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
  }

  private func authenticate(reason: String, result: @escaping FlutterResult) {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
      // 没有可用的系统凭证：交给 Dart 侧回退到应用 PIN。
      result(false)
      return
    }
    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
      DispatchQueue.main.async { result(success) }
    }
  }

  // MARK: - PIN

  private func randomSaltBase64() -> String? {
    var bytes = [UInt8](repeating: 0, count: 16)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      return nil
    }
    return Data(bytes).base64EncodedString()
  }

  private func hashPin(pin: String, salt: String, result: @escaping FlutterResult) {
    guard let saltData = Data(base64Encoded: salt) else {
      result(FlutterError(code: "hash_failed", message: "盐格式不正确", details: nil))
      return
    }
    var derived = [UInt8](repeating: 0, count: Self.pinBytes)
    let status = pin.withCString { passwordPtr -> Int32 in
      saltData.withUnsafeBytes { saltPtr -> Int32 in
        CCKeyDerivationPBKDF(
          CCPBKDFAlgorithm(kCCPBKDF2),
          passwordPtr,
          strlen(passwordPtr),
          saltPtr.bindMemory(to: UInt8.self).baseAddress,
          saltData.count,
          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
          Self.pinIterations,
          &derived,
          derived.count
        )
      }
    }
    guard status == kCCSuccess else {
      result(FlutterError(code: "hash_failed", message: "PIN 处理失败", details: nil))
      return
    }
    result(Data(derived).base64EncodedString())
  }

  // MARK: - 正文封存（Keychain 密钥 + AES-GCM）

  private func sealText(plain: String, result: @escaping FlutterResult) {
    do {
      let key = try loadOrCreateKey()
      let nonce = AES.GCM.Nonce()
      let sealed = try AES.GCM.seal(Data(plain.utf8), using: key, nonce: nonce)
      // 与 Android 一致：base64(iv + 密文 + 16 字节 tag)。
      var payload = Data(sealed.nonce)
      payload.append(sealed.ciphertext)
      payload.append(sealed.tag)
      result(payload.base64EncodedString())
    } catch {
      result(FlutterError(code: "seal_failed", message: "加密失败", details: nil))
    }
  }

  private func openText(payload: String, result: @escaping FlutterResult) {
    guard let data = Data(base64Encoded: payload), data.count > Self.encIvBytes else {
      result(FlutterError(code: "bad_payload", message: "密文格式不正确", details: nil))
      return
    }
    do {
      let key = try loadOrCreateKey()
      let nonceData = data.prefix(Self.encIvBytes)
      let body = data.suffix(from: data.startIndex + Self.encIvBytes)
      guard body.count > 16 else {
        result(FlutterError(code: "bad_payload", message: "密文格式不正确", details: nil))
        return
      }
      let ciphertext = body.prefix(body.count - 16)
      let tag = body.suffix(16)
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: nonceData),
        ciphertext: ciphertext,
        tag: tag
      )
      let plain = try AES.GCM.open(box, using: key)
      result(String(data: plain, encoding: .utf8) ?? "")
    } catch {
      result(FlutterError(code: "open_failed", message: "解密失败", details: nil))
    }
  }

  private func loadOrCreateKey() throws -> SymmetricKey {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess, let data = item as? Data, data.count == 32 {
      return SymmetricKey(data: data)
    }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw NSError(domain: "xiaoji", code: -1, userInfo: [
        NSLocalizedDescriptionKey: "无法生成密钥",
      ])
    }
    let keyData = Data(bytes)
    let add: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
      kSecValueData as String: keyData,
      // 首次解锁后可读：后台自动备份也需要拿到口令密文。
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
    // 并发场景下可能已被别的调用写进去：失败时回读一次。
    if SecItemAdd(add as CFDictionary, nil) != errSecSuccess {
      var retry: CFTypeRef?
      if SecItemCopyMatching(query as CFDictionary, &retry) == errSecSuccess,
         let data = retry as? Data, data.count == 32 {
        return SymmetricKey(data: data)
      }
      throw NSError(domain: "xiaoji", code: -2, userInfo: [
        NSLocalizedDescriptionKey: "无法保存密钥",
      ])
    }
    return SymmetricKey(data: keyData)
  }

  // MARK: - 截屏保护

  private func setSecureScreen(enabled: Bool, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      // sharingType = .none 会同时挡住截屏与录屏，等价于 Android 的 FLAG_SECURE。
      for window in NSApplication.shared.windows {
        window.sharingType = enabled ? .none : .readOnly
      }
      result(true)
    }
  }

  // MARK: - 备份包口令加密（XJENC1）

  private func encryptFile(source: String, target: String, password: String,
                           result: @escaping FlutterResult) {
    guard password.count >= 6 else {
      result(FlutterError(code: "weak_password", message: "备份口令至少 6 位", details: nil))
      return
    }
    guard let plain = try? Data(contentsOf: URL(fileURLWithPath: source)) else {
      result(FlutterError(code: "missing_source", message: "待加密的备份不存在", details: nil))
      return
    }
    var salt = [UInt8](repeating: 0, count: Self.encSaltBytes)
    var iv = [UInt8](repeating: 0, count: Self.encIvBytes)
    guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess,
          SecRandomCopyBytes(kSecRandomDefault, iv.count, &iv) == errSecSuccess else {
      result(FlutterError(code: "encrypt_failed", message: "无法生成随机数", details: nil))
      return
    }
    guard let key = deriveBackupKey(password: password, salt: Data(salt)) else {
      result(FlutterError(code: "encrypt_failed", message: "密钥派生失败", details: nil))
      return
    }
    do {
      let sealed = try AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(data: Data(iv)))
      var output = Data(Self.encMagic.utf8)
      output.append(Data(salt))
      output.append(Data(iv))
      output.append(sealed.ciphertext)
      output.append(sealed.tag)
      let url = URL(fileURLWithPath: target)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try output.write(to: url, options: .atomic)
      result(url.path)
    } catch {
      result(FlutterError(code: "encrypt_failed", message: "加密失败", details: nil))
    }
  }

  private func decryptFile(source: String, target: String, password: String,
                           result: @escaping FlutterResult) {
    guard let raw = try? Data(contentsOf: URL(fileURLWithPath: source)) else {
      result(FlutterError(code: "missing_source", message: "备份文件不存在", details: nil))
      return
    }
    let magicLength = Self.encMagic.utf8.count
    let headerLength = magicLength + Self.encSaltBytes + Self.encIvBytes
    guard raw.count > headerLength,
          String(data: raw.prefix(magicLength), encoding: .ascii) == Self.encMagic else {
      result(FlutterError(code: "not_encrypted", message: "不是加密备份文件", details: nil))
      return
    }
    let salt = raw.subdata(in: magicLength ..< magicLength + Self.encSaltBytes)
    let iv = raw.subdata(in: magicLength + Self.encSaltBytes ..< headerLength)
    let body = raw.suffix(from: raw.startIndex + headerLength)
    guard body.count > 16, let key = deriveBackupKey(password: password, salt: salt) else {
      result(FlutterError(code: "bad_password", message: "口令不正确或文件已损坏", details: nil))
      return
    }
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: iv),
        ciphertext: body.prefix(body.count - 16),
        tag: body.suffix(16)
      )
      let plain = try AES.GCM.open(box, using: key)
      let url = URL(fileURLWithPath: target)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try plain.write(to: url, options: .atomic)
      result(url.path)
    } catch {
      // 认证失败与口令错误不可区分：统一口径，不暴露底层异常。
      try? FileManager.default.removeItem(atPath: target)
      result(FlutterError(code: "bad_password", message: "口令不正确或文件已损坏", details: nil))
    }
  }

  /// PBKDF2-HMAC-SHA1 派生 256 位密钥（与安卓一致，换机可互解）。
  private func deriveBackupKey(password: String, salt: Data) -> SymmetricKey? {
    var derived = [UInt8](repeating: 0, count: 32)
    let status = password.withCString { passwordPtr -> Int32 in
      salt.withUnsafeBytes { saltPtr -> Int32 in
        CCKeyDerivationPBKDF(
          CCPBKDFAlgorithm(kCCPBKDF2),
          passwordPtr,
          strlen(passwordPtr),
          saltPtr.bindMemory(to: UInt8.self).baseAddress,
          salt.count,
          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
          Self.encIterations,
          &derived,
          derived.count
        )
      }
    }
    guard status == kCCSuccess else {
      return nil
    }
    return SymmetricKey(data: Data(derived))
  }

  // MARK: - 系统能力

  private func openUrl(_ raw: String, result: @escaping FlutterResult) {
    guard let url = URL(string: raw) else {
      result(false)
      return
    }
    result(NSWorkspace.shared.open(url))
  }

  /// 保存图片到「图片」文件夹（桌面端没有系统相册）。
  private func saveImage(path: String, result: @escaping FlutterResult) {
    let source = URL(fileURLWithPath: path)
    guard let pictures = FileManager.default.urls(for: .picturesDirectory,
                                                  in: .userDomainMask).first else {
      result(["savedToGallery": false])
      return
    }
    let dir = pictures.appendingPathComponent("小记", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let target = uniqueURL(in: dir, fileName: source.lastPathComponent)
      try FileManager.default.copyItem(at: source, to: target)
      result(["savedToGallery": true])
    } catch {
      result(FlutterError(code: "save_failed", message: "保存图片失败", details: nil))
    }
  }

  /// 「分享长图」在桌面端退化为「另存为」：没有系统分享面板。
  private func shareImage(path: String, result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = (path as NSString).lastPathComponent
      panel.canCreateDirectories = true
      guard panel.runModal() == .OK, let target = panel.url else {
        result(nil)
        return
      }
      do {
        if FileManager.default.fileExists(atPath: target.path) {
          try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: target)
        result(nil)
      } catch {
        result(FlutterError(code: "share_failed", message: "保存图片失败", details: nil))
      }
    }
  }

  private func uniqueURL(in dir: URL, fileName: String) -> URL {
    let base = (fileName as NSString).deletingPathExtension
    let ext = (fileName as NSString).pathExtension
    var candidate = dir.appendingPathComponent(fileName)
    var index = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
      candidate = dir.appendingPathComponent(name)
      index += 1
    }
    return candidate
  }
}
