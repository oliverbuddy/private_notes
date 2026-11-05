package com.xiaoji.xiaoji

import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
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

    override fun onCreate(savedInstanceState: Bundle?) {
        // 必须在 super.onCreate 之前读，super 之后 intent 可能已被引擎消费。
        pendingAction = intent?.getStringExtra(EXTRA_ACTION)
        super.onCreate(savedInstanceState)
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NATIVE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveImage" -> saveImage(call.argument<String>("path"), result)
                    "openUrl" -> openExternalUrl(call.argument<String>("url"), result)
                    else -> result.notImplemented()
                }
            }
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
        try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("no_handler", e.message ?: "无法打开链接", null)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val action = intent.getStringExtra(EXTRA_ACTION) ?: return
        val target = channel
        if (target != null) {
            target.invokeMethod("shortcut", action)
        } else {
            pendingAction = action
        }
    }

    companion object {
        private const val CHANNEL = "xiaoji/shortcuts"
        private const val NATIVE_CHANNEL = "xiaoji/native"
        private const val EXTRA_ACTION = "xiaoji.action"
    }
}
