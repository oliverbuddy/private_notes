package com.xiaoji.xiaoji

import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
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

    /** 其他 App「用其他应用打开」送进来的 Markdown：{name, text}，等 Dart 取走。 */
    private var pendingOpenMarkdown: Map<String, Any?>? = null

    /** 其他 App「用其他应用打开」送进来的 PDF：{name, path}（已拷到缓存），等 Dart 取走。 */
    private var pendingOpenFile: Map<String, String>? = null

    private lateinit var backupBridge: BackupBridge
    private lateinit var securityBridge: SecurityBridge

    override fun onCreate(savedInstanceState: Bundle?) {
        // 必须在 super.onCreate 之前读，super 之后 intent 可能已被引擎消费。
        pendingAction = intent?.getStringExtra(EXTRA_ACTION)
        super.onCreate(savedInstanceState)
        handleShareIntent(intent)
        handleOpenDocumentIntent(intent)
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
                    "shareImage" -> shareImage(call.argument<String>("path"), result)
                    "openFile" -> openLocalFile(call.argument<String>("path"), result)
                    "shareFile" -> shareAttachment(call.argument<String>("path"), result)
                    "openUrl" -> openExternalUrl(call.argument<String>("url"), result)
                    "appInfo" -> appInfo(result)
                    "consumeSharedContent" -> {
                        result.success(pendingShare)
                        pendingShare = null
                    }
                    "consumeOpenedMarkdown" -> {
                        result.success(pendingOpenMarkdown)
                        pendingOpenMarkdown = null
                    }
                    "consumeOpenedFile" -> {
                        result.success(pendingOpenFile)
                        pendingOpenFile = null
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
                        call.argument<String>("mimeType") ?: "application/zip",
                        result,
                    )
                    "inspectZip" -> backupBridge.inspectZip(
                        call.argument<String>("zipPath") ?: "",
                        result,
                    )
                    "encryptFile" -> backupBridge.encryptFile(
                        call.argument<String>("sourcePath") ?: "",
                        call.argument<String>("targetPath") ?: "",
                        call.argument<String>("password") ?: "",
                        result,
                    )
                    "decryptFile" -> backupBridge.decryptFile(
                        call.argument<String>("sourcePath") ?: "",
                        call.argument<String>("targetPath") ?: "",
                        call.argument<String>("password") ?: "",
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

    /**
     * 调起系统分享面板，把生成好的分享长图发给其他 App。
     *
     * 图片在应用缓存目录里，通过 FileProvider 换成 content:// 授权 URI，
     * 只授予读取权限、不需要存储权限；系统分享面板会列出所有能收图片的 App。
     */
    private fun shareImage(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("bad_args", "缺少图片路径", null)
            return
        }
        val file = File(path)
        if (!file.exists() || file.length() == 0L) {
            result.error("missing_file", "图片文件不存在", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = "image/png"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(send, "分享小记")
            chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(chooser)
            result.success(true)
        } catch (error: Exception) {
            Log.w("XiaojiShare", "分享图片失败", error)
            result.error("share_failed", error.message ?: "分享失败", null)
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
     * 用系统 / 第三方应用查看附件（PDF、Office、文本、压缩包等）。
     *
     * 应用私有目录（assets/）不能直接交给别的 App：Dart 侧先把文件拷到缓存
     * 目录，这里再通过 FileProvider 换成 content:// 授权 URI，只授予读取权限，
     * 不需要任何存储权限。没有能处理该类型的应用时返回 `no_viewer`，由 Dart
     * 侧提示用户去装 PDF/Office 查看器。
     */
    private fun openLocalFile(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("bad_args", "缺少文件路径", null)
            return
        }
        val file = File(path)
        if (!file.exists() || file.length() == 0L) {
            result.error("missing_file", "文件不存在", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val view = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeTypeForDocument(file.extension))
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(view)
            result.success(true)
        } catch (error: ActivityNotFoundException) {
            result.error("no_viewer", "没有可打开此文件的应用", null)
        } catch (error: Exception) {
            Log.w("XiaojiFile", "打开附件失败", error)
            result.error("open_failed", error.message ?: "打开失败", null)
        }
    }

    /**
     * 分享任意附件（ACTION_SEND）：本机没有预览器时的兜底出口。
     *
     * 与 [openLocalFile] 共用 FileProvider 与 MIME 推断：Dart 侧已经把文件
     * 拷到缓存目录，这里只负责换成授权 URI 并拉起系统分享面板。
     */
    private fun shareAttachment(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("bad_args", "缺少文件路径", null)
            return
        }
        val file = File(path)
        if (!file.exists() || file.length() == 0L) {
            result.error("missing_file", "文件不存在", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = mimeTypeForDocument(file.extension)
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(send, "分享附件")
            chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(chooser)
            result.success(true)
        } catch (error: Exception) {
            Log.w("XiaojiFile", "分享附件失败", error)
            result.error("share_failed", error.message ?: "分享失败", null)
        }
    }

    /**
     * 附件扩展名 → MIME。
     *
     * 先查一张常见格式表，再退回系统 [MimeTypeMap]：国产 ROM 自带的查看器
     * （WPS、文件管理）大多能接 PDF / Office / 文本，但个别机型对
     * `text/markdown`、`application/vnd.rar` 这些冷门类型识别不全，这里显式
     * 写死最稳。都识别不出时给通配 MIME，让用户自己选应用。
     */
    private fun mimeTypeForDocument(extension: String): String {
        val ext = extension.lowercase()
        return when (ext) {
            "pdf" -> "application/pdf"
            "doc" -> "application/msword"
            "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            "xls" -> "application/vnd.ms-excel"
            "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            "ppt" -> "application/vnd.ms-powerpoint"
            "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            "txt", "log" -> "text/plain"
            "md", "markdown" -> "text/markdown"
            "csv" -> "text/csv"
            "json" -> "application/json"
            "xml" -> "text/xml"
            "html", "htm" -> "text/html"
            "epub" -> "application/epub+zip"
            "zip" -> "application/zip"
            "rar" -> "application/vnd.rar"
            "7z" -> "application/x-7z-compressed"
            "" -> "*/*"
            else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "*/*"
        }
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
        handleOpenDocumentIntent(intent)
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
        // 少数 App 用 SEND + EXTRA_STREAM 传文件：命中 .md 就当「打开 Markdown」
        // 处理（图片分享的 stream 不是 md，这里会返回 null 继续走原逻辑）。
        val stream = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        if (stream != null) {
            readMarkdownUri(stream)?.let {
                pendingOpenMarkdown = it
                return
            }
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

    /**
     * 处理「用其他应用打开 / 分享到小记」送进来的文件。
     *
     * **不设白名单**：任何文件都先落成一条小记（Markdown 读成正文，
     * 其余拷到缓存后由 Dart 决定是内联图片还是附件卡片），避免用户
     * 在「打开方式」里找不到小记。
     *
     * Markdown 优先按 URI 读成字符串而不是长期持有 content:// 授权：微信的
     * 授权是一次性的临时读权限，进程重启后就失效了。其他文件先拷一份
     * 本地副本，导入时再写进笔记的附件目录。
     *
     * 失败时也回传一条带 `error` 的记录，让 Dart 侧能给明确提示，而不是
     * 点了文件却什么反应都没有。
     */
    private fun handleOpenDocumentIntent(intent: Intent?) {
        // 分享图片走 handleShareIntent（可能同时带一段文字）；这里再处理
        // 一次会把同一张图导入两遍。
        if (intent?.action == Intent.ACTION_SEND) {
            val type = intent.type ?: ""
            if (type.startsWith("image/")) {
                return
            }
            // 带正文的文本分享同样由 handleShareIntent 建笔记；只有「纯文件」
            // 分享（没有 EXTRA_TEXT）才在这里按附件导入，避免一条内容两条笔记。
            val sharedText =
                intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            if (type.startsWith("text/") && !sharedText.isNullOrBlank()) {
                return
            }
        }
        val uri = when (intent?.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            else -> null
        } ?: return
        val mime = (intent?.type ?: contentResolver.getType(uri))?.lowercase()
        // Markdown 仍按文本导入（正文直接成为笔记内容）。
        readMarkdownUri(uri, mime)?.let {
            pendingOpenMarkdown = it
            return
        }
        val rawName = displayNameOf(uri)
        // 后缀和 MIME 都认：部分 provider 给的显示名没有扩展名。
        val extension = rawName.substringAfterLast('.', "").lowercase()
        val resolvedExtension =
            if (extension.isEmpty()) extensionForMime(mime) else extension
        // 没有扩展名时按 MIME 补一个，但保留原文件名（附件卡片显示的是它）。
        val name = if (extension.isEmpty() && resolvedExtension != null) {
            "$rawName.$resolvedExtension"
        } else {
            rawName
        }
        // 图片走正文内联，其余都按附件导入详情。
        val kind = if (mime?.startsWith("image/") == true ||
            resolvedExtension in IMAGE_EXTENSIONS
        ) {
            "image"
        } else {
            "file"
        }
        val declaredSize = sizeOf(uri)
        if (declaredSize != null && declaredSize > MAX_OPEN_FILE_BYTES) {
            Log.w("XiaojiOpen", "文件过大，未导入：$name（$declaredSize 字节）")
            pendingOpenFile = mapOf("name" to name, "error" to "too_large")
            return
        }
        val file = copyUriToCache(uri, name)
        if (file == null) {
            Log.w("XiaojiOpen", "复制外部文件失败，未导入：$name")
            pendingOpenFile = mapOf("name" to name, "error" to "copy_failed")
            return
        }
        pendingOpenFile = mapOf(
            "name" to name,
            "path" to file.absolutePath,
            "mime" to (mime ?: ""),
            "kind" to kind,
        )
    }

    /**
     * 把外部文档拷进应用缓存，返回可长期读取的本地文件。
     *
     * 不直接把 content:// 交给预览页/系统查看器：微信等 App 给的是一次性
     * 临时读权限，进程重启或页面重建后就失效；缓存副本也避免长期持有外部授权。
     */
    private fun copyUriToCache(uri: Uri, name: String): File? {
        val declaredSize = sizeOf(uri)
        if (declaredSize != null && declaredSize > MAX_OPEN_FILE_BYTES) {
            Log.w("XiaojiOpen", "文件过大，跳过预览：$name（$declaredSize 字节）")
            return null
        }
        return try {
            val safeName = name.substringAfterLast('/').ifBlank { "attachment.pdf" }
            val target = File(cacheDir, "open-${System.currentTimeMillis()}-$safeName")
            val input = (
                if (uri.scheme == "file") {
                    uri.path?.let { path ->
                        File(path).takeIf { it.exists() }?.inputStream()
                    }
                } else {
                    contentResolver.openInputStream(uri)
                }
                ) ?: return null
            input.use { source ->
                target.outputStream().use { sink -> source.copyTo(sink) }
            }
            if (target.length() == 0L || target.length() > MAX_OPEN_FILE_BYTES) {
                target.delete()
                Log.w("XiaojiOpen", "文件为空或过大：$name")
                null
            } else {
                target
            }
        } catch (error: Exception) {
            Log.w("XiaojiOpen", "复制外部文件失败：$name", error)
            null
        }
    }

    /** 查询外部文件大小；部分 provider 不提供 SIZE 时返回 null。 */
    private fun sizeOf(uri: Uri): Long? {
        return try {
            if (uri.scheme == "file") {
                uri.path?.let { path ->
                    File(path).takeIf { it.exists() }?.length()
                }
            } else {
                contentResolver.query(
                    uri,
                    arrayOf(OpenableColumns.SIZE),
                    null,
                    null,
                    null,
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (index >= 0 && !cursor.isNull(index)) {
                            cursor.getLong(index)
                        } else {
                            null
                        }
                    } else {
                        null
                    }
                }
            }
        } catch (error: Exception) {
            Log.w("XiaojiOpen", "读取文件大小失败", error)
            null
        }
    }

    /**
     * 读 Markdown 文件，返回 {name, text}。
     *
     * 扩展名优先；显示名没有后缀时再看 MIME（部分网盘/聊天 App 只给
     * `text/markdown`，文件名里不带 `.md`）。
     */
    private fun readMarkdownUri(uri: Uri, mimeHint: String? = null): Map<String, Any?>? {
        val name = displayNameOf(uri)
        val lower = name.lowercase()
        val isMarkdown = lower.endsWith(".md") ||
            lower.endsWith(".markdown") ||
            (name.substringAfterLast('.', "").isEmpty() &&
                (mimeHint == "text/markdown" || mimeHint == "text/x-markdown"))
        if (!isMarkdown) {
            return null
        }
        return try {
            val bytes: ByteArray? = if (uri.scheme == "file") {
                uri.path?.let { path -> File(path).takeIf { it.exists() }?.readBytes() }
            } else {
                contentResolver.openInputStream(uri)?.use { it.readBytes() }
            }
            if (bytes == null) {
                null
            } else if (bytes.size > MAX_MARKDOWN_BYTES) {
                Log.w("XiaojiOpen", "Markdown 文件过大：$name")
                null
            } else {
                // 去掉 UTF-8 BOM：编辑器里出现一个看不见的字符会像「多了一个方块」。
                val text = String(bytes, Charsets.UTF_8).removePrefix("\uFEFF")
                if (text.isBlank()) null else mapOf("name" to name, "text" to text)
            }
        } catch (error: Exception) {
            Log.w("XiaojiOpen", "读取 Markdown 失败", error)
            null
        }
    }

    /** 文件显示名：优先 content provider 的 DISPLAY_NAME，退回 URI 末段。 */
    private fun displayNameOf(uri: Uri): String {
        if (uri.scheme == "file") {
            return uri.lastPathSegment?.substringAfterLast('/') ?: FALLBACK_MARKDOWN_NAME
        }
        try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (index >= 0) {
                        val value = cursor.getString(index)
                        if (!value.isNullOrBlank()) {
                            return value
                        }
                    }
                }
            }
        } catch (error: Exception) {
            Log.w("XiaojiOpen", "读取文件名失败", error)
        }
        return uri.lastPathSegment?.substringAfterLast('/') ?: FALLBACK_MARKDOWN_NAME
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

        /** 单篇导入的 Markdown 体积上限：超过这个值多半是误分享的大文件。 */
        private const val MAX_MARKDOWN_BYTES = 5 * 1024 * 1024

        /** 外部文件导入的体积上限：更大的文件拷贝与落盘都太慢。 */
        private const val MAX_OPEN_FILE_BYTES = 200L * 1024 * 1024

        /** 按扩展名识别图片（部分 provider 的 MIME 不可靠）。 */
        private val IMAGE_EXTENSIONS = setOf(
            "jpg", "jpeg", "png", "webp", "gif", "bmp", "heic", "heif", "avif",
        )

        private fun extensionForMime(mime: String?): String? = when (mime) {
            "application/pdf" -> "pdf"
            "text/plain" -> "txt"
            "text/csv" -> "csv"
            "text/html" -> "html"
            "text/xml", "application/xml" -> "xml"
            "application/json" -> "json"
            "application/msword" -> "doc"
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document" -> "docx"
            "application/vnd.ms-excel" -> "xls"
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" -> "xlsx"
            "application/vnd.ms-powerpoint" -> "ppt"
            "application/vnd.openxmlformats-officedocument.presentationml.presentation" -> "pptx"
            "application/rtf" -> "rtf"
            "application/vnd.oasis.opendocument.text" -> "odt"
            "application/vnd.oasis.opendocument.spreadsheet" -> "ods"
            "application/vnd.oasis.opendocument.presentation" -> "odp"
            else -> null
        }

        /** 取不到文件名时的兜底名字。 */
        private const val FALLBACK_MARKDOWN_NAME = "导入的笔记.md"
    }
}
