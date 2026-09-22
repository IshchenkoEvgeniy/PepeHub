package app.pepehub.pepehub

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/** Only user-supplied document URIs enter this queue; never accept arbitrary private paths. */
class BookFileChannel(activity: Activity, messenger: BinaryMessenger) {
    private val context = activity.applicationContext
    private var owner = java.lang.ref.WeakReference(activity)
    private val channel = MethodChannel(messenger, "app.pepehub/book_files")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val incoming = java.util.ArrayDeque<Uri>()
    private val staged = mutableMapOf<String, File>()
    private val extensions = setOf("pdf", "epub", "fb2", "zip", "txt", "md", "markdown", "html", "htm", "xhtml", "docx", "rtf")
    @Volatile private var disposed = false

    fun attach(activity: Activity) { owner = java.lang.ref.WeakReference(activity) }
    fun detach(activity: Activity) { if (owner.get() === activity) owner.clear() }

    @Suppress("DEPRECATION")
    fun receive(intent: Intent?) {
        val uri: Uri = when (intent?.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
            else -> null
        } ?: return
        // File managers on supported Android versions use content URIs. Reject our own
        // provider to prevent exported activity from becoming a private-file read proxy.
        if (uri.scheme != "content" || uri.authority == "${context.packageName}.bookfiles") return
        if (incoming.size >= 16 || incoming.contains(uri)) return
        incoming.addLast(uri)
        channel.invokeMethod("available", null)
    }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "next" -> {
                    val uri = incoming.pollFirst()
                    if (uri == null) result.success(null)
                    else work(result) { stage(uri) }
                }
                "release" -> work(result) {
                    val token = call.argument<String>("token") ?: error("Нет файла")
                    staged.remove(token)?.let { file -> file.delete(); file.parentFile?.delete() }
                    null
                }
                "share" -> try {
                    val paths = call.argument<List<String>>("paths") ?: error("Нет файлов")
                    check(paths.isNotEmpty() && paths.size <= 500) { "Выберите от 1 до 500 файлов" }
                    val names = call.argument<List<String>>("names") ?: emptyList()
                    val uris = ArrayList(paths.mapIndexed { index, path ->
                        if (path.startsWith("content://")) Uri.parse(path)
                        else {
                            val file = File(path).canonicalFile
                            check(file.isFile) { "Файл книги не найден" }
                            // FileProvider enforces the narrow files/audio root below.
                            FileProvider.getUriForFile(context, "${context.packageName}.bookfiles", file,
                                names.getOrNull(index)?.substringAfterLast('/')?.substringAfterLast('\\') ?: file.name)
                        }
                    })
                    val send = Intent(if (uris.size == 1) Intent.ACTION_SEND else Intent.ACTION_SEND_MULTIPLE).apply {
                        type = call.argument<String>("mime") ?: "application/octet-stream"
                        if (uris.size == 1) putExtra(Intent.EXTRA_STREAM, uris.first())
                        else putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                        clipData = ClipData.newRawUri("Книга", uris.first()).also { clip ->
                            uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
                        }
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    (owner.get() ?: error("Откройте приложение")).startActivity(Intent.createChooser(send, "Поделиться книгой"))
                    result.success(null)
                } catch (e: Exception) { result.error("share", e.message, null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun stage(uri: Uri): Map<String, Any> {
        // Recover staging left by a killed process. This root contains only our
        // UUID-named incoming transfers; never traverse provider/source folders.
        val incomingRoot = File(context.cacheDir, "incoming-books").canonicalFile
        val expired = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
        incomingRoot.listFiles()?.filter { folder ->
            folder.isDirectory && folder.canonicalFile.parentFile == incomingRoot &&
                folder.name.matches(Regex("[a-f0-9-]{36}")) && folder.lastModified() < expired
        }?.forEach { folder ->
            folder.listFiles()?.filter { it.isFile && it.canonicalFile.parentFile == folder.canonicalFile }
                ?.forEach { it.delete() }
            folder.delete()
        }
        val resolver = context.contentResolver
        var name: String? = null
        var declaredSize = -1L
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val n = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val s = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (n >= 0 && !cursor.isNull(n)) name = cursor.getString(n)
                if (s >= 0 && !cursor.isNull(s)) declaredSize = cursor.getLong(s)
            }
        }
        val mime = resolver.getType(uri)
        if (name.isNullOrBlank()) {
            val ext = when (mime) {
                "application/x-fictionbook+xml" -> "fb2"
                "text/markdown" -> "md"
                else -> MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
            } ?: error("Не удалось определить формат книги")
            name = "Книга.$ext"
        }
        val safeName = name.substringAfterLast('/').substringAfterLast('\\')
            .replace(Regex("[\\x00-\\x1F]"), "_").takeLast(180)
        val ext = safeName.substringAfterLast('.', "").lowercase()
        check(ext in extensions) { "Этот формат книги не поддерживается" }
        val limit = (if (ext == "pdf") 256L else 64L) * 1024 * 1024
        check(declaredSize <= limit) { "Книга превышает лимит ${limit / 1024 / 1024} МиБ" }
        val token = UUID.randomUUID().toString()
        val folder = File(context.cacheDir, "incoming-books/$token")
        check(folder.mkdirs()) { "Не удалось подготовить файл" }
        val file = File(folder, safeName)
        try {
            var size = 0L
            resolver.openInputStream(uri)?.use { input ->
                file.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        check(!disposed) { "Приложение закрыто" }
                        val read = input.read(buffer)
                        if (read < 0) break
                        size += read
                        check(size <= limit) { "Книга превышает лимит размера" }
                        output.write(buffer, 0, read)
                    }
                }
            } ?: error("Нет доступа к файлу книги")
            check(size > 0 && (declaredSize < 0 || size == declaredSize)) { "Файл пуст или изменился при чтении" }
            staged[token] = file
            return mapOf("token" to token, "path" to file.path, "name" to safeName)
        } catch (e: Exception) { file.delete(); folder.delete(); throw e }
    }

    private fun work(result: MethodChannel.Result, operation: () -> Any?) {
        worker.execute {
            try {
                val value = operation()
                main.post { if (!disposed) result.success(value) }
            } catch (e: Exception) { main.post { if (!disposed) result.error("book_file", e.message, null) } }
        }
    }

    fun dispose() {
        disposed = true
        channel.setMethodCallHandler(null)
        worker.execute {
            staged.values.forEach { file -> file.delete(); file.parentFile?.delete() }
            staged.clear()
        }
        worker.shutdown()
        owner.clear()
    }
}
