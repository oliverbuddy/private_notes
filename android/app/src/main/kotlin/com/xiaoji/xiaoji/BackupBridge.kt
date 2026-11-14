package com.xiaoji.xiaoji

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodChannel
import java.io.DataInputStream
import java.io.File
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.CipherInputStream
import javax.crypto.CipherOutputStream
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec
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

        /** 明文 zip 与口令加密包的分界标记，Dart 侧读前 6 字节判断。 */
        private const val ENC_MAGIC = "XJENC1"
        private const val ENC_SALT_BYTES = 16
        private const val ENC_IV_BYTES = 12
        private const val GCM_TAG_BITS = 128
        private const val PBKDF2_ITERATIONS = 150_000
        private const val KEY_BITS = 256

        /** manifest.json 读取上限：摘要文件只是几十字节，超限视为异常包。 */
        private const val MAX_MANIFEST_BYTES = 64 * 1024
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
                if (name.startsWith(prefix) &&
                    (name.endsWith(".zip") || name.endsWith(".xiaoji"))
                ) {
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
            val emitted = HashSet<String>()
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
                        emitted.add(entryName)
                    }
                // overrides 里还有源目录不存在的条目（manifest.json 就是这种）：
                // 它们不是「替换」，而是「额外写入」，必须单独补一遍，
                // 否则备份包永远拿不到摘要。
                overrideMap.forEach { (entryName, sourcePath) ->
                    if (entryName in emitted) {
                        return@forEach
                    }
                    if (excludes.any {
                            entryName == it || entryName.startsWith("$it/")
                        }
                    ) {
                        return@forEach
                    }
                    val payload = File(sourcePath)
                    if (!payload.exists()) {
                        return@forEach
                    }
                    zip.putNextEntry(ZipEntry(entryName))
                    payload.inputStream().buffered().use { it.copyTo(zip) }
                    zip.closeEntry()
                    emitted.add(entryName)
                }
            }
            result.success(target.absolutePath)
        } catch (e: Exception) {
            result.error("zip_failed", e.message ?: "压缩失败", null)
        }
    }

    /**
     * 读取备份包摘要，不解压任何内容。
     *
     * 优先取包内 `manifest.json`；旧包没有 manifest 时用条目名扫描出
     * 笔记数 / 附件数，恢复前仍能给出可核对的信息。
     */
    fun inspectZip(zipPath: String, result: MethodChannel.Result) {
        try {
            val zip = File(zipPath)
            if (!zip.exists()) {
                result.error("missing_zip", "备份文件不存在", null)
                return
            }
            var manifest: String? = null
            var notes = 0
            var assets = 0
            ZipInputStream(zip.inputStream().buffered()).use { input ->
                var entry: ZipEntry? = input.nextEntry
                while (entry != null) {
                    val name = entry.name.replace('\\', '/')
                    val lower = name.lowercase()
                    if (name == "manifest.json" &&
                        entry.size in 0..MAX_MANIFEST_BYTES
                    ) {
                        manifest = input.readBytes().toString(Charsets.UTF_8)
                    } else if (lower.endsWith(".md") && !lower.endsWith(".tmp")) {
                        notes += 1
                    } else if (name.startsWith("assets/")) {
                        assets += 1
                    }
                    input.closeEntry()
                    entry = input.nextEntry
                }
            }
            result.success(
                mapOf(
                    "manifest" to manifest,
                    "noteCount" to notes,
                    "assetCount" to assets,
                ),
            )
        } catch (e: Exception) {
            result.error("inspect_failed", e.message ?: "读取备份信息失败", null)
        }
    }

    // -------------------------------------------------------------------------
    // 口令加密（导出 / 外置备份）
    // -------------------------------------------------------------------------

    /**
     * 用口令加密整份备份文件。
     *
     * 格式：`XJENC1` + 16 字节盐 + 12 字节 IV + AES-256-GCM 密文（含认证标签）。
     * 密钥由 PBKDF2-HMAC-SHA1 派生 —— 选 SHA1 是为了 API 24 也能解，
     * 换机恢复不会因为新旧系统不同而打不开。
     */
    fun encryptFile(
        sourcePath: String,
        targetPath: String,
        password: String,
        result: MethodChannel.Result,
    ) {
        try {
            val source = File(sourcePath)
            if (!source.exists()) {
                result.error("missing_source", "待加密的备份不存在", null)
                return
            }
            if (password.length < 6) {
                result.error("weak_password", "备份口令至少 6 位", null)
                return
            }
            val salt = ByteArray(ENC_SALT_BYTES).also { SecureRandom().nextBytes(it) }
            val iv = ByteArray(ENC_IV_BYTES).also { SecureRandom().nextBytes(it) }
            val key = deriveKey(password, salt)
            val target = File(targetPath)
            target.parentFile?.mkdirs()
            target.outputStream().buffered().use { output ->
                output.write(ENC_MAGIC.toByteArray(Charsets.US_ASCII))
                output.write(salt)
                output.write(iv)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(
                    Cipher.ENCRYPT_MODE,
                    key,
                    GCMParameterSpec(GCM_TAG_BITS, iv),
                )
                CipherOutputStream(output, cipher).use { cipherOut ->
                    source.inputStream().buffered().use { it.copyTo(cipherOut) }
                }
            }
            result.success(target.absolutePath)
        } catch (e: Exception) {
            result.error("encrypt_failed", e.message ?: "加密失败", null)
        }
    }

    /** 解密 [encryptFile] 生成的文件；口令不对时返回 `bad_password`。 */
    fun decryptFile(
        sourcePath: String,
        targetPath: String,
        password: String,
        result: MethodChannel.Result,
    ) {
        val target = File(targetPath)
        try {
            val source = File(sourcePath)
            if (!source.exists()) {
                result.error("missing_source", "备份文件不存在", null)
                return
            }
            DataInputStream(source.inputStream().buffered()).use { data ->
                val magic = ByteArray(ENC_MAGIC.length)
                data.readFully(magic)
                if (String(magic, Charsets.US_ASCII) != ENC_MAGIC) {
                    result.error("not_encrypted", "不是加密备份文件", null)
                    return
                }
                val salt = ByteArray(ENC_SALT_BYTES)
                data.readFully(salt)
                val iv = ByteArray(ENC_IV_BYTES)
                data.readFully(iv)
                val key = deriveKey(password, salt)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(
                    Cipher.DECRYPT_MODE,
                    key,
                    GCMParameterSpec(GCM_TAG_BITS, iv),
                )
                target.parentFile?.mkdirs()
                CipherInputStream(data, cipher).use { cipherIn ->
                    target.outputStream().buffered().use { cipherIn.copyTo(it) }
                }
            }
            result.success(target.absolutePath)
        } catch (e: Exception) {
            // GCM 认证失败在流式解密里会以 IOException 形式抛出：统一口径，
            // 不把底层异常名暴露给用户。
            try {
                if (target.exists()) {
                    target.delete()
                }
            } catch (_: Exception) {
                // 半截明文删不掉也不能留在临时目录里被误用，交由 cleanTempDir 兜底。
            }
            result.error("bad_password", "口令不正确或文件已损坏", null)
        }
    }

    private fun deriveKey(password: String, salt: ByteArray): SecretKey {
        val spec = PBEKeySpec(password.toCharArray(), salt, PBKDF2_ITERATIONS, KEY_BITS)
        try {
            val factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA1")
            return SecretKeySpec(factory.generateSecret(spec).encoded, "AES")
        } finally {
            spec.clearPassword()
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
    fun saveFileToUser(
        sourcePath: String,
        fileName: String,
        mimeType: String,
        result: MethodChannel.Result,
    ) {
        val source = File(sourcePath)
        if (!source.exists()) {
            result.error("missing_source", "临时文件不存在", null)
            return
        }
        pendingResult = result
        pendingSource = sourcePath
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // 加密包不是 zip（扩展名 .xiaoji），用通用二进制类型，
            // 避免系统文件管理器把它当压缩包打开。
            type = mimeType.ifBlank { MIME_ZIP }
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
