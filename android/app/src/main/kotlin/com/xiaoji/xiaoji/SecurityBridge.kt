package com.xiaoji.xiaoji

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.view.WindowManager
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec

/**
 * 安全相关原生能力：
 *  1. 系统凭证解锁（设备 PIN / 图案 / 指纹）；
 *  2. 笔记正文 AES-256-GCM 加解密（密钥在 Android Keystore，不出设备）；
 *  3. 备用 PIN 的 PBKDF2 哈希；
 *  4. FLAG_SECURE 截屏保护。
 *
 * 不引入第三方依赖，全部用 Android 框架能力。
 */
internal class SecurityBridge(private val activity: Activity) {

    private var pendingAuth: MethodChannel.Result? = null

    companion object {
        private const val REQUEST_AUTH = 4102
        private const val KEY_ALIAS = "xiaoji-note-key-v1"
        private const val GCM_TAG_BITS = 128
        private const val PBKDF2_ITERATIONS = 120_000
        private const val PBKDF2_BITS = 256
    }

    /** 设备是否设置了安全锁屏（PIN / 图案 / 密码 / 生物识别）。 */
    fun isDeviceSecure(result: MethodChannel.Result) {
        val keyguard =
            activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        result.success(keyguard.isDeviceSecure)
    }

    /** 唤起系统凭证验证；用户在系统界面取消或失败返回 false。 */
    fun authenticate(reason: String, result: MethodChannel.Result) {
        val keyguard =
            activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (!keyguard.isDeviceSecure) {
            result.success(false)
            return
        }
        val intent = keyguard.createConfirmDeviceCredentialIntent("解锁小记", reason)
        if (intent == null) {
            result.success(false)
            return
        }
        if (pendingAuth != null) {
            result.error("busy", "正在等待上一次验证", null)
            return
        }
        pendingAuth = result
        try {
            activity.startActivityForResult(intent, REQUEST_AUTH)
        } catch (e: Exception) {
            pendingAuth = null
            result.error("auth_failed", e.message ?: "无法打开系统验证", null)
        }
    }

    /** 供 Activity 的 onActivityResult 调用；返回 true 表示本次结果已处理。 */
    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != REQUEST_AUTH) {
            return false
        }
        val result = pendingAuth ?: return true
        pendingAuth = null
        result.success(resultCode == Activity.RESULT_OK)
        return true
    }

    /** 生成 16 字节盐（base64），给 Dart 侧存进 settings.json。 */
    fun randomSalt(result: MethodChannel.Result) {
        val bytes = ByteArray(16)
        SecureRandom().nextBytes(bytes)
        result.success(Base64.encodeToString(bytes, Base64.NO_WRAP))
    }

    /** PBKDF2 哈希备用 PIN；salt 为 base64 字节串。 */
    fun hashPin(pin: String, saltBase64: String, result: MethodChannel.Result) {
        try {
            val salt = Base64.decode(saltBase64, Base64.NO_WRAP)
            val algorithm =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    "PBKDF2WithHmacSHA256"
                } else {
                    "PBKDF2WithHmacSHA1"
                }
            val spec = PBEKeySpec(
                pin.toCharArray(),
                salt,
                PBKDF2_ITERATIONS,
                PBKDF2_BITS,
            )
            val factory = SecretKeyFactory.getInstance(algorithm)
            val hash = factory.generateSecret(spec).encoded
            spec.clearPassword()
            result.success(Base64.encodeToString(hash, Base64.NO_WRAP))
        } catch (e: Exception) {
            result.error("hash_failed", e.message ?: "PIN 处理失败", null)
        }
    }

    /** 用 Keystore 密钥加密正文；返回 base64(iv + ciphertext)。 */
    fun sealText(plain: String, result: MethodChannel.Result) {
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
            val iv = cipher.iv
            val encrypted = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
            val combined = iv + encrypted
            result.success(Base64.encodeToString(combined, Base64.NO_WRAP))
        } catch (e: Exception) {
            result.error("seal_failed", e.message ?: "加密失败", null)
        }
    }

    /** 解密 sealText 生成的 base64(iv + ciphertext)。 */
    fun openText(payload: String, result: MethodChannel.Result) {
        try {
            val bytes = Base64.decode(payload, Base64.NO_WRAP)
            if (bytes.size < 12) {
                result.error("bad_payload", "密文格式不正确", null)
                return
            }
            val iv = bytes.copyOfRange(0, 12)
            val cipherText = bytes.copyOfRange(12, bytes.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                getOrCreateKey(),
                GCMParameterSpec(GCM_TAG_BITS, iv),
            )
            result.success(String(cipher.doFinal(cipherText), Charsets.UTF_8))
        } catch (e: Exception) {
            result.error("open_failed", e.message ?: "解密失败", null)
        }
    }

    /** 禁止/恢复截屏与多任务预览。 */
    fun setSecureScreen(enabled: Boolean, result: MethodChannel.Result) {
        activity.runOnUiThread {
            if (enabled) {
                activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            } else {
                activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
            result.success(true)
        }
    }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)
            ?.let { return it.secretKey }

        val generator =
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }
}
