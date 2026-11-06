package com.xiaoji.xiaoji

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/**
 * 备份相关的原生实现：流式压缩 / 解压 / 系统「另存为」。
 *
 * 全部走文件流，Dart 侧只传路径 —— 图多、笔记多的用户导出时不会因为
 * 把整个 zip 读成字节数组而 OOM。
 */
internal class BackupBridge(private val activity: Activity) {

    private var pendingResult: MethodChannel.Result? = null
    private var pendingSource: String? = null
    private var pendingTree: MethodChannel.Result? = null

    companion object {
        private const val REQUEST_SAVE = 4101
        private const val REQUEST_TREE = 4103
        private const val MIME_ZIP = "application/zip"
    }

    // -------------------------------------------------------------------------
    // 外置备份目录（SAF）
    // -------------------------------------------------------------------------

    /** 让用户选一个文件夹作为外置备份位置；授权会持久化，重启后仍可写入。 */
    fun pickDirectory(result: MethodChannel.Result) {
        if (pendingTree != null) {
            result.error("busy", "正在等待上一次选择", null)
            return
        }
        pendingTree = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
            )
        }
        try {
            activity.startActivityForResult(intent, REQUEST_TREE)
        } catch (e: Exception) {
            pendingTree = null
            result.error("no_picker", e.message ?: "无法打开文件夹选择器", null)
        }
    }

    /**
     * 把 [sourcePath] 写入用户选定的目录，并按前缀保留最近 [keep] 份。
     *
     * 走 DocumentsContract 而不是第三方库：只要一个 ZIP 的落盘 + 列表清理，
     * 用系统 API 就够，也不必处理存储权限。
     */
    fun writeToTree(
        treeUri: String,
        sourcePath: String,
        fileName: String,
        keepPrefix: String,
        keep: Int,
        result: MethodChannel.Result,
    ) {
        try {
            val tree = Uri.parse(treeUri)
            val resolver = activity.contentResolver
            val treeDocId = DocumentsContract.getTreeDocumentId(tree)
            val parent = DocumentsContract.buildDocumentUriUsingTree(tree, treeDocId)
            val created = DocumentsContract.createDocument(
                resolver,
                parent,
                MIME_ZIP,
                fileName,
            ) ?: throw IllegalStateException("无法在所选文件夹里创建文件")

            File(sourcePath).inputStream().buffered().use { input ->
                resolver.openOutputStream(created)?.use { output ->
                    input.copyTo(output)
                } ?: throw IllegalStateException("无法写入所选文件夹")
            }

            pruneTree(tree, keepPrefix, keep, created)

            result.success(created.toString())
        } catch (e: Exception) {
            result.error("tree_write_failed", e.message ?: "写入外置备份失败", null)
        }
    }

    /** 删除同前缀的旧备份，只保留最新 [keep] 份（含刚写入的那份）。 */
    private fun pruneTree(tree: Uri, prefix: String, keep: Int, keepUri: Uri) {
        if (keep <= 0) {
            return
        }
        val resolver = activity.contentResolver
        val treeDocId = DocumentsContract.getTreeDocumentId(tree)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, treeDocId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        val items = mutableListOf<Triple<String, String, Long>>()
        resolver.query(children, projection, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getString(0) ?: continue
                val name = cursor.getString(1) ?: continue
                val modified = if (cursor.isNull(2)) 0L else cursor.getLong(2)
                if (name.startsWith(prefix) && name.endsWith(".zip")) {
                    items.add(Triple(id, name, modified))
                }
            }
        }
        items.sortByDescending { it.third }
        val keepDocId = DocumentsContract.getDocumentId(keepUri)
        for (index in keep until items.size) {
            val id = items[index].first
            if (id == keepDocId) {
                continue
            }
            try {
                DocumentsContract.deleteDocument(
                    resolver,
                    DocumentsContract.buildDocumentUriUsingTree(tree, id),
                )
            } catch (_: Exception) {
                // 某个文件删不掉（只读目录 / 被占用）不影响备份结果。
            }
        }
    }

    /** 把 [sourceRoot] 下的文件打成 zip 写到 [targetPath]。 */
    fun zipTree(
        sourceRoot: String,
        targetPath: String,
        excludePaths: List<String>?,
        overrides: Map<String, String>?,
        result: MethodChannel.Result,
    ) {
        try {
            val source = File(sourceRoot)
            if (!source.exists()) {
                result.error("missing_source", "笔记目录不存在", null)
                return
            }
            val excludes = excludePaths ?: emptyList()
            val overrideMap = overrides ?: emptyMap()
            val target = File(targetPath)
            target.parentFile?.mkdirs()
            ZipOutputStream(target.outputStream().buffered()).use { zip ->
                source.walkTopDown()
                    .onEnter { it == source || it.name != "tmp" }
                    .filter { it.isFile && !it.name.endsWith(".tmp") }
                    .forEach { file ->
                        val entryName = file.relativeTo(source).invariantSeparatorsPath
                        // 默认排除锁定笔记：路径完全匹配，或落在被排除的目录下。
                        if (excludes.any {
                                entryName == it || entryName.startsWith("$it/")
                            }
                        ) {
                            return@forEach
                        }
                        zip.putNextEntry(ZipEntry(entryName))
                        val payload = overrideMap[entryName]?.let { File(it) } ?: file
                        payload.inputStream().buffered().use { it.copyTo(zip) }
                        zip.closeEntry()
                    }
            }
            result.success(target.absolutePath)
        } catch (e: Exception) {
            result.error("zip_failed", e.message ?: "压缩失败", null)
        }
    }

    /** 把 [zipPath] 解压到 [destDir]（拒绝 `..` 越目录）。 */
    fun unzipTo(zipPath: String, destDir: String, result: MethodChannel.Result) {
        try {
            val zip = File(zipPath)
            if (!zip.exists()) {
                result.error("missing_zip", "备份文件不存在", null)
                return
            }
            val dest = File(destDir)
            dest.mkdirs()
            ZipInputStream(zip.inputStream().buffered()).use { input ->
                var entry: ZipEntry? = input.nextEntry
                while (entry != null) {
                    val name = entry.name.replace('\\', '/')
                    if (name.contains("..")) {
                        // 恶意压缩包：跳过该条目，继续解其余内容。
                        entry = input.nextEntry
                        continue
                    }
                    val target = File(dest, name)
                    if (entry.isDirectory) {
                        target.mkdirs()
                    } else {
                        target.parentFile?.mkdirs()
                        target.outputStream().buffered().use { output ->
                            input.copyTo(output)
                        }
                    }
                    input.closeEntry()
                    entry = input.nextEntry
                }
            }
            result.success(dest.absolutePath)
        } catch (e: Exception) {
            result.error("unzip_failed", e.message ?: "解压失败", null)
        }
    }

    /**
     * 拉起系统「另存为」，把 [sourcePath] 流式复制到用户选的位置。
     *
     * 用 ACTION_CREATE_DOCUMENT 而不是插件：插件要求把文件字节交给 Dart
     * 再回传，大文件一样会 OOM。这里只传 URI，复制在原生侧完成。
     */
    fun saveFileToUser(sourcePath: String, fileName: String, result: MethodChannel.Result) {
        val source = File(sourcePath)
        if (!source.exists()) {
            result.error("missing_source", "临时文件不存在", null)
            return
        }
        pendingResult = result
        pendingSource = sourcePath
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = MIME_ZIP
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        try {
            activity.startActivityForResult(intent, REQUEST_SAVE)
        } catch (e: Exception) {
            pendingResult = null
            pendingSource = null
            result.error("no_picker", e.message ?: "无法打开保存对话框", null)
        }
    }

    /** 供 Activity 的 onActivityResult 调用；返回 true 表示本次结果已处理。 */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == REQUEST_TREE) {
            val result = pendingTree
            pendingTree = null
            if (result == null) {
                return true
            }
            val uri: Uri? = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) {
                // 用户取消：Dart 侧按 null 处理。
                result.success(null)
                return true
            }
            try {
                activity.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            } catch (e: Exception) {
                // 个别 ROM 不允许持久化：本次授权仍然可用，只是重启后要重选。
            }
            result.success(uri.toString())
            return true
        }
        if (requestCode != REQUEST_SAVE) {
            return false
        }
        val result = pendingResult
        val source = pendingSource
        pendingResult = null
        pendingSource = null
        if (result == null) {
            return true
        }
        val uri: Uri? = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            // 用户取消：Dart 侧按 null 处理，静默返回。
            result.success(null)
            return true
        }
        try {
            val src = File(source ?: "")
            activity.contentResolver.openOutputStream(uri)?.use { output ->
                src.inputStream().buffered().use { it.copyTo(output) }
            } ?: throw IllegalStateException("无法写入所选位置")
            result.success(uri.toString())
        } catch (e: Exception) {
            result.error("copy_failed", e.message ?: "写入失败", null)
        }
        return true
    }
}
