package app.pepehub.pepehub

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.provider.DocumentsContract as Docs
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Persistent read-only media documents. No staging or whole-file copies. */
class VideoFilesChannel(activity: Activity, messenger: BinaryMessenger) {
    private val context = activity.applicationContext
    private var owner = java.lang.ref.WeakReference(activity)
    private val channel = MethodChannel(messenger, "app.pepehub/video_files")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var pendingFrame: ByteArray? = null
    @Volatile private var disposed = false
    private val extensions = setOf("mp4", "mkv", "webm", "mov", "m4v", "avi", "mpeg", "mpg", "mp3", "m4a", "m4b", "aac", "flac", "wav", "ogg", "opus", "wma", "aiff", "aif")

    fun attach(activity: Activity) { owner = java.lang.ref.WeakReference(activity) }
    fun detach(activity: Activity) { if (owner.get() === activity) owner.clear() }

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "verifyFiles") {
                worker.execute {
                    try {
                        val files = call.argument<List<Map<String, Any?>>>("files") ?: error("Список файлов отсутствует")
                        check(files.size <= 10000) { "Слишком много файлов" }
                        for (file in files) {
                            val expected = file["identity"] as? Map<*, *> ?: continue
                            val actual = identity(Uri.parse(file["uri"] as String)) ?: error("Файл недоступен")
                            for (key in arrayOf("size", "modifiedMs", "fingerprint", "sample")) {
                                check(actual[key].toString() == expected[key].toString()) { "Файл изменился. Повторите обновление папки" }
                            }
                        }
                        main.post { if (!disposed) result.success(true) }
                    } catch (e: Exception) { main.post { if (!disposed) result.error("video_files", e.message, null) } }
                }
                return@setMethodCallHandler
            }
            if (call.method == "scanFolder") {
                if (pending != null) result.error("busy", "Выбор файла уже открыт", null)
                else worker.execute {
                    try {
                        val root = Uri.parse(call.argument<String>("root") ?: error("Папка не выбрана"))
                        val response = scan(root)
                        main.post { if (!disposed) result.success(response) }
                    } catch (e: Exception) { main.post { if (!disposed) result.error("video_files", e.message, null) } }
                }
                return@setMethodCallHandler
            }
            if (call.method != "pickFiles" && call.method != "pickFolder" && call.method != "pickSubtitle" && call.method != "saveFrame") {
                result.notImplemented()
            } else if (pending != null) {
                result.error("busy", "Выбор медиа уже открыт", null)
            } else {
                try {
                    val folder = call.method == "pickFolder"
                    val subtitle = call.method == "pickSubtitle"
                    val saveFrame = call.method == "saveFrame"
                    if (saveFrame) {
                        val args = call.arguments as? Map<*, *> ?: error("Некорректный снимок")
                        pendingFrame = args["bytes"] as? ByteArray ?: error("Кадр не получен")
                        check(pendingFrame!!.size in 1..32 * 1024 * 1024) { "Снимок больше 32 МиБ" }
                    }
                    pending = result
                    val intent = Intent(if (saveFrame) Intent.ACTION_CREATE_DOCUMENT else if (folder) Intent.ACTION_OPEN_DOCUMENT_TREE else Intent.ACTION_OPEN_DOCUMENT).apply {
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                        if (folder) addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION) else {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = if (saveFrame) "image/png" else "*/*"
                            if (saveFrame) {
                                val name = (call.argument<String>("name") ?: "PepeHub-frame.png").replace(Regex("[\\\\/\\x00]"), "_").take(150)
                                putExtra(Intent.EXTRA_TITLE, name)
                                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                            }
                            if (subtitle) putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("text/plain", "text/vtt", "application/x-subrip", "text/x-ass", "application/octet-stream"))
                            if (!subtitle && !saveFrame) putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("video/*", "audio/*", "application/ogg", "application/x-flac"))
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, !subtitle && !saveFrame)
                        }
                    }
                    (owner.get() ?: error("Откройте приложение")).startActivityForResult(intent, if (saveFrame) 4723 else if (folder) 4721 else if (subtitle) 4722 else 4720)
                } catch (e: Exception) {
                    pending = null
                    pendingFrame = null
                    result.error("video_files", e.message, null)
                }
            }
        }
    }

    fun onActivityResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request !in 4720..4723) return false
        val result = pending ?: return true
        if (code != Activity.RESULT_OK || data == null) {
            pending = null
            pendingFrame = null
            result.success(null)
            return true
        }
        worker.execute {
            try {
                val response: Any?
                if (request == 4723) {
                    val uri = data.data ?: error("Путь не выбран")
                    val bytes = pendingFrame ?: error("Снимок не получен")
                    context.contentResolver.openOutputStream(uri, "wt")?.use { it.write(bytes) } ?: error("Не удалось записать кадр")
                    response = uri.toString()
                } else if (request == 4722) {
                    val uri = data.data ?: error("Файл не выбран")
                    val bytes = java.io.ByteArrayOutputStream()
                    context.contentResolver.openInputStream(uri)?.use { input ->
                        val buffer = ByteArray(8192)
                        while (true) {
                            check(!disposed) { "Приложение закрыто" }
                            val count = input.read(buffer)
                            if (count < 0) break
                            check(bytes.size() + count <= 8 * 1024 * 1024) { "Субтитры больше 8 МиБ" }
                            bytes.write(buffer, 0, count)
                        }
                    } ?: error("Файл недоступен")
                    response = mapOf("name" to name(uri), "bytes" to bytes.toByteArray())
                } else if (request == 4721) {
                    val tree = data.data ?: error("Папка не выбрана")
                    persist(tree)
                    response = scan(tree)
                } else {
                    val uris = mutableListOf<Uri>()
                    data.clipData?.let { clip ->
                        for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
                    }
                    if (uris.isEmpty()) data.data?.let { uris.add(it) }
                    check(uris.size in 1..10000) { "Выберите от 1 до 10000 медиафайлов" }
                    val files = uris.distinct().map { uri ->
                        persist(uri)
                        mapOf("uri" to uri.toString(), "name" to name(uri), "audio" to (context.contentResolver.getType(uri)?.startsWith("audio/") == true), "identity" to identity(uri))
                    }
                    response = mapOf("title" to if (files.size == 1) files[0]["name"].toString().substringBeforeLast('.') else "Новая подборка", "files" to files)
                }
                main.post {
                    pending = null
                    pendingFrame = null
                    if (!disposed) result.success(response)
                }
            } catch (e: Exception) {
                main.post {
                    pending = null
                    pendingFrame = null
                    if (!disposed) result.error("video_files", e.message, null)
                }
            }
        }
        return true
    }

    private fun persist(uri: Uri) {
        context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }

    private fun name(uri: Uri): String {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) return cursor.getString(0)
        }
        return "Медиа"
    }

    private fun scan(tree: Uri): Map<String, Any?> {
        val files = mutableListOf<Map<String, Any?>>()
        var entries = 0
        fun visit(id: String, prefix: String, depth: Int) {
            check(!disposed) { "Приложение закрыто" }
            check(depth <= 32) { "Слишком много вложенных папок (максимум 32)" }
            val children = Docs.buildChildDocumentsUriUsingTree(tree, id)
            context.contentResolver.query(children, arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME, Docs.Document.COLUMN_MIME_TYPE), null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    check(++entries <= 50000) { "В папке больше 50000 элементов" }
                    val childId = cursor.getString(0)
                    val title = cursor.getString(1) ?: "Медиа"
                    val path = if (prefix.isEmpty()) title else "$prefix/$title"
                    if (cursor.getString(2) == Docs.Document.MIME_TYPE_DIR) {
                        if (!title.equals(".pepehub", ignoreCase = true)) visit(childId, path, depth + 1)
                    } else if (title.substringAfterLast('.', "").lowercase() in extensions) {
                        val uri = Docs.buildDocumentUriUsingTree(tree, childId)
                        files.add(mapOf("uri" to uri.toString(), "name" to path, "identity" to identity(uri)))
                        check(files.size <= 10000) { "В папке больше 10000 медиафайлов" }
                    }
                }
            } ?: error("Папка недоступна")
        }
        val rootId = Docs.getTreeDocumentId(tree)
        visit(rootId, "", 0)
        return mapOf("title" to name(Docs.buildDocumentUriUsingTree(tree, rootId)), "root" to tree.toString(), "files" to files)
    }

    private fun identity(uri: Uri): Map<String, Any?>? {
        return runCatching {
            var size = -1L
            var modified = 0L
            context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE, Docs.Document.COLUMN_LAST_MODIFIED), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    if (!cursor.isNull(0)) size = cursor.getLong(0)
                    if (!cursor.isNull(1)) modified = cursor.getLong(1)
                }
            }
            if (size < 0) return@runCatching null
            val digest = java.security.MessageDigest.getInstance("SHA-256")
            digest.update("head-v1:$size:".toByteArray(Charsets.UTF_8))
            context.contentResolver.openInputStream(uri)?.use { input ->
                val buffer = ByteArray(8192)
                var remaining = 65536
                while (remaining > 0) {
                    check(!disposed) { "Приложение закрыто" }
                    val count = input.read(buffer, 0, minOf(buffer.size, remaining))
                    if (count < 0) break
                    digest.update(buffer, 0, count)
                    remaining -= count
                }
            } ?: return@runCatching null
            mapOf("size" to size, "modifiedMs" to modified, "fingerprint" to digest.digest().joinToString("") { "%02x".format(it) }, "sample" to "head-v1")
        }.getOrNull()
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        pending?.error("video_files", "Приложение закрыто", null)
        pending = null
        pendingFrame = null
        worker.shutdown()
    }
}
