package com.xiaoji.xiaoji

import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 原生桥接：
 *  1. 「长按图标 → 新建小记」快捷方式动作（xiaoji/shortcuts）；
 *  2. 系统动作：图片保存到相册、打开外部链接（xiaoji/native）。
 */
class MainActivity : FlutterActivity() {

    private var pendingAction: String? = null
    private var channel: MethodChannel? = null

    /** 其他 App 分享进来的内容，等 Dart 侧取走。 */
    private var pendingShare: Map<String, Any?>? = null

    private lateinit var backupBridge: BackupBridge
    private lateinit var securityBridge: SecurityBridge

    override fun onCreate(savedInstanceState: Bundle?) {
        // 必须在 super.onCreate 之前读，super 之后 intent 可能已被引擎消费。
        pendingAction = intent?.getStringExtra(EXTRA_ACTION)
        super.onCreate(savedInstanceState)
        handleShareIntent(intent)
        // 手势导航：页面已铺到系统栏后面，但导航栏底色默认是主题黑，
        // 底部会露出一条黑边。这里把导航栏背景设为透明，让页面底色透上来；
        // 同时关掉系统给导航栏加的对比度遮罩（否则仍是半透明灰条）。
        window.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumeInitialAction" -> {
                    result.success(pendingAction)
                    pendingAction = null
                }
                else -> result.notImplemented()
            }
        }
        // 系统动作独立通道：相册写入、打开外部链接，与启动快捷方式无关。
        backupBridge = BackupBridge(this)
        securityBridge = SecurityBridge(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NATIVE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isDeviceSecure" -> securityBridge.isDeviceSecure(result)
                    "authenticate" -> securityBridge.authenticate(
                        call.argument<String>("reason") ?: "验证身份",
                        result,
                    )
                    "randomSalt" -> securityBridge.randomSalt(result)
                    "hashPin" -> securityBridge.hashPin(
                        call.argument<String>("pin") ?: "",
                        call.argument<String>("salt") ?: "",
                        result,
                    )
                    "sealText" -> securityBridge.sealText(
                        call.argument<String>("text") ?: "",
                        result,
                    )
                    "openText" -> securityBridge.openText(
                        call.argument<String>("payload") ?: "",
                        result,
                    )
                    "setSecureScreen" -> securityBridge.setSecureScreen(
                        call.argument<Boolean>("enabled") ?: false,
                        result,
                    )
                    "saveImage" -> saveImage(call.argument<String>("path"), result)
                    "openUrl" -> openExternalUrl(call.argument<String>("url"), result)
                    "appInfo" -> appInfo(result)
                    "consumeSharedContent" -> {
                        result.success(pendingShare)
                        pendingShare = null
                    }
                    "zipTree" -> backupBridge.zipTree(
                        call.argument<String>("sourceRoot") ?: "",
                        call.argument<String>("targetPath") ?: "",
                        call.argument<List<String>>("excludes"),
                        call.argument<Map<String, String>>("overrides"),
                        result,
                    )
                    "unzipTo" -> backupBridge.unzipTo(
                        call.argument<String>("zipPath") ?: "",
                        call.argument<String>("destDir") ?: "",
                        result,
                    )
                    "saveFileToUser" -> backupBridge.saveFileToUser(
                        call.argument<String>("sourcePath") ?: "",
                        call.argument<String>("fileName") ?: "backup.zip",
                        result,
                    )
                    "pickDirectory" -> backupBridge.pickDirectory(result)
                    "writeToTree" -> backupBridge.writeToTree(
                        call.argument<String>("treeUri") ?: "",
                        call.argument<String>("sourcePath") ?: "",
                        call.argument<String>("fileName") ?: "backup.zip",
                        call.argument<String>("keepPrefix") ?: "xiaoji-",
                        call.argument<Int>("keep") ?: 3,
                        result,
                    )
                    else -> result.notImplemented()
                }
            }
        // 剪贴板通道：Flutter 的 Clipboard 只能取 text/plain，网页复制通常
        // 还带 text/html。这里把 HTML 一并交给 Dart 侧转成 Markdown。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CLIPBOARD_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getHtml" -> result.success(readClipboardHtml())
                    else -> result.notImplemented()
                }
            }
    }

    /** 读取剪贴板第一项的 HTML；没有 HTML 风味时返回 null。 */
    private fun readClipboardHtml(): String? {
        return try {
            val manager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = manager.primaryClip
            if (clip == null || clip.itemCount == 0) {
                null
            } else {
                clip.getItemAt(0).htmlText?.takeIf { it.isNotBlank() }
            }
        } catch (error: Exception) {
            Log.w("XiaojiClipboard", "读取剪贴板 HTML 失败", error)
            null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (::backupBridge.isInitialized &&
            backupBridge.onActivityResult(requestCode, resultCode, data)
        ) {
            return
        }
        if (::securityBridge.isInitialized &&
            securityBridge.onActivityResult(requestCode, resultCode)
        ) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    /**
     * 把 [path] 指向的图片写入系统相册。
     *
     * Android 10+ 走 MediaStore（Pictures/小记），无需存储权限；
     * 更低的系统退回应用专属目录（同样不需要权限，但不在系统相册里），
     * 返回 savedToGallery=false，由 Dart 侧给出对应提示。
     */
    private fun saveImage(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("bad_args", "缺少图片路径", null)
            return
        }
        val source = File(path)
        if (!source.exists()) {
            result.error("missing_file", "图片文件不存在", null)
            return
        }
        try {
            val name = "xiaoji_${System.currentTimeMillis()}.${source.extension.ifBlank { "jpg" }}"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, name)
                    put(MediaStore.Images.Media.MIME_TYPE, mimeTypeFor(source.extension))
                    put(
                        MediaStore.Images.Media.RELATIVE_PATH,
                        Environment.DIRECTORY_PICTURES + "/小记"
                    )
                    // 写入完成前标记 pending，相册不会先看到一个半截文件。
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                val uri = contentResolver.insert(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    values
                ) ?: throw IllegalStateException("媒体库拒绝写入")
                contentResolver.openOutputStream(uri)?.use { output ->
                    source.inputStream().use { input -> input.copyTo(output) }
                } ?: throw IllegalStateException("无法打开输出流")
                values.clear()
                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                contentResolver.update(uri, values, null, null)
                result.success(mapOf("savedToGallery" to true, "path" to uri.toString()))
            } else {
                val dir = getExternalFilesDir(Environment.DIRECTORY_PICTURES)
                    ?: throw IllegalStateException("无法访问外部存储")
                dir.mkdirs()
                val target = File(dir, name)
                source.inputStream().use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                }
                result.success(
                    mapOf("savedToGallery" to false, "path" to target.absolutePath)
                )
            }
        } catch (e: Exception) {
            result.error("save_failed", e.message ?: "保存失败", null)
        }
    }

    private fun mimeTypeFor(extension: String): String = when (extension.lowercase()) {
        "png" -> "image/png"
        "webp" -> "image/webp"
        "gif" -> "image/gif"
        "heic", "heif" -> "image/heic"
        else -> "image/jpeg"
    }

    /**
     * 版本信息：从已安装的 APK 里读，避免 Dart 侧手写版本号与 pubspec 漂移。
     */
    private fun appInfo(result: MethodChannel.Result) {
        try {
            val info = packageManager.getPackageInfo(packageName, 0)
            val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toLong()
            }
            result.success(
                mapOf(
                    "versionName" to (info.versionName ?: ""),
                    "versionCode" to versionCode,
                    "packageName" to packageName,
                ),
            )
        } catch (error: Exception) {
            result.error("app_info_failed", error.message, null)
        }
    }

    /**
     * 用系统浏览器/对应 App 打开 http(s)、mailto、tel、sms 链接。
     *
     * 只认这几类协议：正文里的附件链接（assets/…）不能交给 ACTION_VIEW，
     * 否则会弹「没有应用可执行此操作」。
     */
    private fun openExternalUrl(url: String?, result: MethodChannel.Result) {
        if (url.isNullOrBlank()) {
            result.error("bad_args", "缺少链接地址", null)
            return
        }
        // 只放行这几类协议。正文里的链接来自用户输入/粘贴，如果交给
        // ACTION_VIEW 处理 file://、content://、intent:// 等，笔记里的一行
        // 文本就可能触发本机文件或任意组件，属于不该有的攻击面。
        val uri = Uri.parse(url)
        val scheme = uri.scheme?.lowercase()
        if (scheme !in ALLOWED_URL_SCHEMES) {
            result.error("unsupported_scheme", "不支持打开该协议的链接", null)
            return
        }
        try {
            val intent = Intent(Intent.ACTION_VIEW, uri)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("no_handler", e.message ?: "无法打开链接", null)
        }
    }

    override fun onDestroy() {
        // 系统验证页还开着时 Activity 被回收：给 Dart 侧一个结果，
        // 否则解锁按钮会一直停在「验证中」。
        if (::securityBridge.isInitialized) {
            securityBridge.onDestroy()
        }
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShareIntent(intent)
        val action = intent.getStringExtra(EXTRA_ACTION) ?: return
        val target = channel
        if (target != null) {
            target.invokeMethod("shortcut", action)
        } else {
            pendingAction = action
        }
    }

    /**
     * 系统分享导入：只接 ACTION_SEND 的文本与单张图片。
     *
     * 图片先 copy 到应用缓存目录，再交给 Dart 落到 `assets/<noteId>/`，
     * 避免长期持有外部 content:// 授权。多图（SEND_MULTIPLE）暂不支持。
     */
    private fun handleShareIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) {
            return
        }
        val type = intent.type ?: return
        if (type.startsWith("text/")) {
            val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            if (!text.isNullOrBlank()) {
                pendingShare = mapOf("type" to "text", "text" to text)
            }
            return
        }
        if (type.startsWith("image/")) {
            val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM) ?: return
            val file = copySharedImageToCache(uri) ?: return
            pendingShare = mapOf("type" to "image", "path" to file.absolutePath)
        }
    }

    private fun copySharedImageToCache(uri: Uri): File? {
        return try {
            val target = File(cacheDir, "share-${System.currentTimeMillis()}.jpg")
            contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            }
            target.takeIf { it.length() > 0 }
        } catch (error: Exception) {
            null
        }
    }

    companion object {
        private const val CHANNEL = "xiaoji/shortcuts"
        private const val NATIVE_CHANNEL = "xiaoji/native"
        private const val CLIPBOARD_CHANNEL = "xiaoji/clipboard"

        /** 快捷方式 / 桌面小组件带过来的动作 extra。 */
        const val EXTRA_ACTION = "xiaoji.action"

        /** 动作值：新建一条小记。 */
        const val ACTION_NEW_NOTE = "new_note"

        /** 允许交给系统浏览器/拨号/SMS 的协议。 */
        private val ALLOWED_URL_SCHEMES =
            setOf("http", "https", "mailto", "tel", "sms", "smsto")
    }
}
