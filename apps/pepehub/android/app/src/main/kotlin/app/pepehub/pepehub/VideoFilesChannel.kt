package app.pepehub.pepehub

import android.Manifest
import android.app.Activity
import android.content.ContentUris
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
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
    // Automatic search can take a while; picking and verifying stay responsive.
    private val discoveryWorker = Executors.newSingleThreadExecutor()
    // Previews decode frames; two at a time keep the list responsive.
    private val thumbnailWorker = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    private var pendingFrame: ByteArray? = null
    private var pendingDiscovery: Pair<MethodChannel.Result, Pair<List<String>, Boolean>>? = null
    private var discovering = false
    @Volatile private var discoveryCancelled = false
    @Volatile private var disposed = false
    private var pendingDelete: DeleteRequest? = null

    /** Files waiting for Android's delete confirmation. */
    private class DeleteRequest(
        val result: MethodChannel.Result,
        val deleted: MutableList<String>,
        val failed: MutableList<String>,
        val media: List<String>,
    )
    private val extensions = setOf("mp4", "mkv", "webm", "mov", "m4v", "avi", "mpeg", "mpg", "mp3", "m4a", "m4b", "aac", "flac", "wav", "ogg", "opus", "wma", "aiff", "aif")
    private val videoExtensions = setOf("mp4", "mkv", "webm", "mov", "m4v", "avi", "mpeg", "mpg")

    companion object {
        private const val MEDIA_PERMISSION = 4725
        private const val DELETE_REQUEST = 4727
        private const val TREE_REQUEST = 4728
    }

    fun attach(activity: Activity) { owner = java.lang.ref.WeakReference(activity) }
    fun detach(activity: Activity) {
        if (owner.get() === activity) {
            owner.clear()
            pendingDiscovery?.first?.error("video_files", "Откройте поиск видео повторно", null)
            pendingDiscovery = null
        }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "cancelDiscovery") {
                discoveryCancelled = true
                result.success(null)
                return@setMethodCallHandler
            }
            if (call.method == "discover") {
                try {
                    check(!discovering && pendingDiscovery == null) { "Поиск уже идёт" }
                    val roots = (call.argument<List<String>>("roots") ?: emptyList()).distinct()
                    check(roots.size <= 100) { "Не больше 100 папок для поиска" }
                    var device = call.argument<Boolean>("device") == true
                    // Background search never asks for access: it skips the media index.
                    if (device && call.argument<Boolean>("quiet") == true && !hasMediaPermission()) device = false
                    check(roots.isNotEmpty() || device) { "Выберите папки или поиск по всему устройству" }
                    if (device && !hasMediaPermission()) {
                        val activity = owner.get() ?: error("Откройте приложение")
                        pendingDiscovery = result to (roots to device)
                        activity.requestPermissions(arrayOf(mediaPermission()), MEDIA_PERMISSION)
                    } else {
                        discover(result, roots, device)
                    }
                } catch (e: Exception) {
                    result.error("video_files", e.message, null)
                }
                return@setMethodCallHandler
            }
            if (call.method == "thumbnail") {
                val source = call.argument<String>("uri")
                val size = (call.argument<Int>("size") ?: 320).coerceIn(64, 640)
                if (source == null) { result.success(null); return@setMethodCallHandler }
                thumbnailWorker.execute {
                    val bytes = runCatching { thumbnail(Uri.parse(source), size) }.getOrNull()
                    main.post { if (!disposed) result.success(bytes) }
                }
                return@setMethodCallHandler
            }
            if (call.method == "deleteFiles") {
                if (pendingDelete != null) { result.error("busy", "Удаление уже идёт", null); return@setMethodCallHandler }
                val uris = call.argument<List<String>>("uris") ?: emptyList()
                worker.execute {
                    try {
                        check(uris.size <= 10000) { "Слишком много файлов" }
                        deleteFiles(uris, result)
                    } catch (e: Exception) { main.post { if (!disposed) result.error("video_files", e.message, null) } }
                }
                return@setMethodCallHandler
            }
            if (call.method == "checkSources") {
                worker.execute {
                    try {
                        val uris = call.argument<List<String>>("uris") ?: emptyList()
                        check(uris.size <= 20000) { "Слишком много файлов" }
                        val response = checkSources(uris)
                        main.post { if (!disposed) result.success(response) }
                    } catch (e: Exception) { main.post { if (!disposed) result.error("video_files", e.message, null) } }
                }
                return@setMethodCallHandler
            }
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
            if (call.method == "pickTree") {
                if (pending != null) { result.error("busy", "Выбор медиа уже открыт", null); return@setMethodCallHandler }
                try {
                    pending = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        // Write access lets PepeHub delete files the user chooses to delete.
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                    }
                    (owner.get() ?: error("Откройте приложение")).startActivityForResult(intent, TREE_REQUEST)
                } catch (e: Exception) {
                    pending = null
                    result.error("video_files", e.message, null)
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
                        if (folder) addFlags(Intent.FLAG_GRANT_PREFIX_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) else {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = if (saveFrame) (call.argument<String>("mime")?.takeIf { it.startsWith("image/") } ?: "image/png") else "*/*"
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
        if (request == DELETE_REQUEST) {
            val waiting = pendingDelete ?: return true
            pendingDelete = null
            if (code == Activity.RESULT_OK) waiting.deleted.addAll(waiting.media) else waiting.failed.addAll(waiting.media)
            if (!disposed) waiting.result.success(mapOf("deleted" to waiting.deleted, "failed" to waiting.failed))
            return true
        }
        // 4724 belongs to book picking, which MainActivity asks first.
        if (request !in 4720..4723 && request != TREE_REQUEST) return false
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
                if (request == TREE_REQUEST) {
                    val tree = data.data ?: error("Папка не выбрана")
                    persist(tree)
                    response = mapOf("root" to tree.toString(), "title" to name(Docs.buildDocumentUriUsingTree(tree, Docs.getTreeDocumentId(tree))))
                } else if (request == 4723) {
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
        // Write is kept when Android granted it; reading alone is enough to play.
        val both = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        try {
            context.contentResolver.takePersistableUriPermission(uri, both)
        } catch (e: SecurityException) {
            context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
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

    private fun mediaPermission() =
        if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_VIDEO else Manifest.permission.READ_EXTERNAL_STORAGE

    private fun hasMediaPermission() =
        context.checkSelfPermission(mediaPermission()) == PackageManager.PERMISSION_GRANTED

    fun onPermissions(code: Int, grants: IntArray): Boolean {
        if (code != MEDIA_PERMISSION) return false
        val waiting = pendingDiscovery ?: return true
        pendingDiscovery = null
        if (grants.isNotEmpty() && grants[0] == PackageManager.PERMISSION_GRANTED) {
            discover(waiting.first, waiting.second.first, waiting.second.second)
        } else {
            waiting.first.error("permission", "Нет доступа к видео на устройстве. Разрешите «Видео» для PepeHub в настройках Android или ищите по выбранным папкам", null)
        }
        return true
    }

    /** Lists videos without opening them: names, sizes and dates only. */
    private fun discover(result: MethodChannel.Result, roots: List<String>, device: Boolean) {
        discovering = true
        discoveryCancelled = false
        discoveryWorker.execute {
            val files = ArrayList<Map<String, Any?>>()
            val seen = HashSet<String>()
            val errors = ArrayList<String>()
            var lastReport = 0L
            fun add(file: Map<String, Any?>) {
                if (!seen.add(file["uri"] as String)) return
                files.add(file)
                check(files.size <= 50000) { "Найдено больше 50000 видео. Сузьте папки поиска" }
                val now = System.currentTimeMillis()
                if (now - lastReport > 250) {
                    lastReport = now
                    val count = files.size
                    main.post { if (!disposed) channel.invokeMethod("discoveryProgress", count) }
                }
            }
            try {
                for (root in roots) {
                    try {
                        scanTreeForVideos(Uri.parse(root), ::add)
                    } catch (e: SecurityException) {
                        errors.add("${rootTitle(root)}: нет доступа, подключите папку заново")
                    } catch (e: IllegalArgumentException) {
                        errors.add("${rootTitle(root)}: папка недоступна, подключите её заново")
                    } catch (e: IllegalStateException) {
                        if (discoveryCancelled || disposed || e.message?.startsWith("Найдено больше") == true) throw e
                        errors.add("${rootTitle(root)}: ${e.message}")
                    }
                }
                if (device) scanMediaStore(::add)
                check(!discoveryCancelled) { "Поиск отменён" }
                val response = mapOf("files" to files, "errors" to errors)
                main.post { discovering = false; if (!disposed) result.success(response) }
            } catch (e: Exception) {
                val cancelled = discoveryCancelled
                main.post {
                    discovering = false
                    if (!disposed) result.error(if (cancelled) "cancelled" else "video_files", e.message, null)
                }
            }
        }
    }

    private fun rootTitle(root: String): String = runCatching {
        val tree = Uri.parse(root)
        Docs.getTreeDocumentId(tree).substringAfter(':').ifEmpty { "Папка" }
    }.getOrDefault("Папка")

    private fun checkDiscovery() {
        check(!disposed) { "Приложение закрыто" }
        check(!discoveryCancelled) { "Поиск отменён" }
    }

    private fun scanTreeForVideos(tree: Uri, add: (Map<String, Any?>) -> Unit) {
        val rootId = Docs.getTreeDocumentId(tree)
        val title = name(Docs.buildDocumentUriUsingTree(tree, rootId))
        var entries = 0
        val projection = arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME, Docs.Document.COLUMN_MIME_TYPE, Docs.Document.COLUMN_SIZE, Docs.Document.COLUMN_LAST_MODIFIED)
        fun visit(id: String, prefix: String, depth: Int) {
            checkDiscovery()
            if (depth > 32) return
            val children = Docs.buildChildDocumentsUriUsingTree(tree, id)
            val folders = ArrayList<Pair<String, String>>()
            context.contentResolver.query(children, projection, null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    checkDiscovery()
                    check(++entries <= 500000) { "Больше 500000 элементов в папке" }
                    val childId = cursor.getString(0) ?: continue
                    val childName = cursor.getString(1) ?: continue
                    val path = "$prefix/$childName"
                    if (cursor.getString(2) == Docs.Document.MIME_TYPE_DIR) {
                        // Hidden folders hold thumbnails, caches and app data.
                        if (!childName.startsWith(".")) folders.add(childId to path)
                    } else if (childName.substringAfterLast('.', "").lowercase() in videoExtensions) {
                        add(mapOf(
                            "uri" to Docs.buildDocumentUriUsingTree(tree, childId).toString(),
                            "path" to path,
                            "size" to if (cursor.isNull(3)) 0L else cursor.getLong(3),
                            "modifiedMs" to if (cursor.isNull(4)) 0L else cursor.getLong(4),
                        ))
                    }
                }
            } ?: error("папка недоступна")
            // The cursor is closed before descending: deep trees keep one open.
            for ((childId, path) in folders) visit(childId, path, depth + 1)
        }
        visit(rootId, title, 0)
    }

    private fun scanMediaStore(add: (Map<String, Any?>) -> Unit) {
        // Column names as strings: DURATION, RELATIVE_PATH and VOLUME_NAME moved
        // between API levels, the names themselves did not.
        val collection = if (Build.VERSION.SDK_INT >= 29) MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL) else MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        val projection = if (Build.VERSION.SDK_INT >= 29) arrayOf("_id", "_display_name", "_size", "date_modified", "duration", "relative_path", "volume_name")
            else arrayOf("_id", "_display_name", "_size", "date_modified", "duration", "_data")
        @Suppress("DEPRECATION")
        val storage = android.os.Environment.getExternalStorageDirectory().absolutePath.trimEnd('/')
        context.contentResolver.query(collection, projection, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                checkDiscovery()
                val id = cursor.getLong(0)
                val fileName = cursor.getString(1) ?: continue
                val uri: Uri
                val path: String
                if (Build.VERSION.SDK_INT >= 29) {
                    val volume = cursor.getString(6) ?: MediaStore.VOLUME_EXTERNAL_PRIMARY
                    val relative = (cursor.getString(5) ?: "").trim('/')
                    val prefix = if (volume == MediaStore.VOLUME_EXTERNAL_PRIMARY) relative else if (relative.isEmpty()) "Карта памяти" else "Карта памяти/$relative"
                    path = if (prefix.isEmpty()) fileName else "$prefix/$fileName"
                    uri = ContentUris.withAppendedId(MediaStore.Video.Media.getContentUri(volume), id)
                } else {
                    val data = cursor.getString(5) ?: continue
                    path = if (data.startsWith("$storage/")) data.removePrefix("$storage/") else data.trimStart('/')
                    uri = ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, id)
                }
                add(mapOf(
                    "uri" to uri.toString(),
                    "path" to path,
                    "size" to if (cursor.isNull(2)) 0L else cursor.getLong(2),
                    "modifiedMs" to if (cursor.isNull(3)) 0L else cursor.getLong(3) * 1000,
                    "durationMs" to if (cursor.isNull(4)) null else cursor.getLong(4),
                ))
            }
        } ?: error("Медиатека Android недоступна")
    }

    /** A small JPEG frame: the system thumbnail when there is one, else a decoded frame. */
    private fun thumbnail(uri: Uri, size: Int): ByteArray? {
        check(!disposed) { "Приложение закрыто" }
        var bitmap: android.graphics.Bitmap? = null
        if (Build.VERSION.SDK_INT >= 29 && uri.authority == MediaStore.AUTHORITY) {
            bitmap = runCatching { context.contentResolver.loadThumbnail(uri, android.util.Size(size, size), null) }.getOrNull()
        }
        if (bitmap == null) {
            val retriever = android.media.MediaMetadataRetriever()
            try {
                retriever.setDataSource(context, uri)
                val duration = retriever.extractMetadata(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                // A tenth in, at most 30 s: past black intros, never past the end.
                val atUs = minOf(duration / 10, 30_000L).coerceAtLeast(0L) * 1000
                val option = android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                bitmap = if (Build.VERSION.SDK_INT >= 27) retriever.getScaledFrameAtTime(atUs, option, size, size)
                    else retriever.getFrameAtTime(atUs, option)
                if (bitmap == null) bitmap = retriever.frameAtTime
            } finally {
                runCatching { retriever.release() }
            }
        }
        val frame = bitmap ?: return null
        val scale = minOf(1f, size.toFloat() / maxOf(frame.width, frame.height))
        val scaled = if (scale < 1f) android.graphics.Bitmap.createScaledBitmap(frame, maxOf(1, (frame.width * scale).toInt()), maxOf(1, (frame.height * scale).toInt()), true) else frame
        val out = java.io.ByteArrayOutputStream()
        scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, out)
        if (scaled !== frame) scaled.recycle()
        frame.recycle()
        return out.toByteArray()
    }

    /**
     * Which sources still exist. Only certain answers are returned: a source
     * that cannot be checked (no permission, unknown provider) is in neither list.
     */
    private fun checkSources(uris: List<String>): Map<String, List<String>> {
        val missing = ArrayList<String>()
        val present = ArrayList<String>()
        val media = LinkedHashMap<Uri, MutableMap<Long, String>>()
        val canReadMedia = hasMediaPermission()
        for (source in uris.distinct()) {
            check(!disposed) { "Приложение закрыто" }
            val uri = Uri.parse(source)
            when {
                uri.scheme == "content" && uri.authority == MediaStore.AUTHORITY -> {
                    // Without access the index hides other apps' files: unknown, not missing.
                    if (!canReadMedia) continue
                    val id = runCatching { ContentUris.parseId(uri) }.getOrNull() ?: continue
                    if (id < 0) continue
                    val path = uri.path ?: continue
                    val collection = uri.buildUpon().path(path.substringBeforeLast('/')).build()
                    media.getOrPut(collection) { HashMap() }[id] = source
                }
                uri.scheme == "content" -> try {
                    val cursor = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                    val exists = cursor?.use { it.moveToFirst() } ?: false
                    if (exists) present.add(source) else missing.add(source)
                } catch (e: SecurityException) {
                    // The folder lost its permission: the file may well be there.
                } catch (e: IllegalArgumentException) {
                    missing.add(source)
                } catch (e: Exception) {
                    // Unknown provider failure: no answer.
                }
                uri.scheme == "file" || uri.scheme == null -> {
                    val path = uri.path ?: source
                    if (java.io.File(path).exists()) present.add(source) else missing.add(source)
                }
            }
        }
        for ((collection, byId) in media) {
            for (chunk in byId.keys.toList().chunked(500)) {
                check(!disposed) { "Приложение закрыто" }
                val found = HashSet<Long>()
                val cursor = try {
                    context.contentResolver.query(collection, arrayOf("_id"), "_id IN (${chunk.joinToString(",") { "?" }})", chunk.map { it.toString() }.toTypedArray(), null)
                } catch (e: Exception) { null } ?: continue
                cursor.use { while (it.moveToNext()) found.add(it.getLong(0)) }
                for (id in chunk) (if (id in found) present else missing).add(byId[id]!!)
            }
        }
        return mapOf("missing" to missing, "present" to present)
    }

    /**
     * Deletes files from the device. Files of Android's media index are deleted
     * after the system confirmation; folder documents directly, or through the
     * media index when the folder was connected read-only.
     */
    private fun deleteFiles(uris: List<String>, result: MethodChannel.Result) {
        val deleted = ArrayList<String>()
        val failed = ArrayList<String>()
        val media = LinkedHashMap<Uri, String>()
        for (source in uris.distinct()) {
            check(!disposed) { "Приложение закрыто" }
            val uri = Uri.parse(source)
            when {
                uri.scheme == "content" && uri.authority == MediaStore.AUTHORITY -> media[uri] = source
                uri.scheme == "content" -> {
                    val removed = runCatching { Docs.deleteDocument(context.contentResolver, uri) }.getOrDefault(false)
                    if (removed) deleted.add(source)
                    else mediaFor(uri)?.let { media[it] = source } ?: failed.add(source)
                }
                else -> {
                    val file = java.io.File(uri.path ?: source)
                    if (file.delete() || !file.exists()) deleted.add(source) else failed.add(source)
                }
            }
        }
        fun finish() = main.post { if (!disposed) result.success(mapOf("deleted" to deleted, "failed" to failed)) }
        if (media.isEmpty()) { finish(); return }
        if (Build.VERSION.SDK_INT >= 30) {
            val request = MediaStore.createDeleteRequest(context.contentResolver, media.keys.toList())
            main.post {
                val activity = owner.get()
                if (activity == null || disposed) {
                    failed.addAll(media.values)
                    if (!disposed) result.success(mapOf("deleted" to deleted, "failed" to failed))
                    return@post
                }
                pendingDelete = DeleteRequest(result, deleted, failed, media.values.toList())
                try {
                    activity.startIntentSenderForResult(request.intentSender, DELETE_REQUEST, null, 0, 0, 0)
                } catch (e: Exception) {
                    pendingDelete = null
                    failed.addAll(media.values)
                    result.success(mapOf("deleted" to deleted, "failed" to failed))
                }
            }
            return
        }
        for ((uri, source) in media) {
            val removed = runCatching { context.contentResolver.delete(uri, null, null) > 0 }.getOrDefault(false)
            (if (removed) deleted else failed).add(source)
        }
        finish()
    }

    /** The media index entry of a folder document: same name and size. */
    private fun mediaFor(document: Uri): Uri? = runCatching {
        if (Build.VERSION.SDK_INT < 30 || !hasMediaPermission()) return@runCatching null
        var name: String? = null
        var size = -1L
        context.contentResolver.query(document, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                name = cursor.getString(0)
                if (!cursor.isNull(1)) size = cursor.getLong(1)
            }
        }
        if (name == null || size < 0) return@runCatching null
        for (collection in arrayOf(MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL), MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL))) {
            context.contentResolver.query(collection, arrayOf("_id"), "_display_name=? AND _size=?", arrayOf(name, size.toString()), null)?.use { cursor ->
                // Only an unambiguous match: never delete a different copy.
                if (cursor.count == 1 && cursor.moveToFirst()) return@runCatching ContentUris.withAppendedId(collection, cursor.getLong(0))
            }
        }
        null
    }.getOrNull()

    fun dispose() {
        disposed = true
        discoveryCancelled = true
        pendingDiscovery?.first?.error("video_files", "Приложение закрыто", null)
        pendingDiscovery = null
        pendingDelete?.result?.error("video_files", "Приложение закрыто", null)
        pendingDelete = null
        discoveryWorker.shutdown()
        thumbnailWorker.shutdown()
        channel.setMethodCallHandler(null)
        pending?.error("video_files", "Приложение закрыто", null)
        pending = null
        pendingFrame = null
        worker.shutdown()
    }
}
