package app.pepehub.pepehub

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract as Docs
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.Executors
import org.json.JSONObject

/** Persistent SAF sources; the player opens document URIs directly. */
class AudioFolderChannel(contextSource: android.content.Context, messenger: BinaryMessenger) {
    private val context = contextSource.applicationContext
    private var owner = java.lang.ref.WeakReference(contextSource as? Activity)
    fun attach(activity: Activity) { owner = java.lang.ref.WeakReference(activity) }
    fun detach(activity: Activity) { if (owner.get() === activity) owner.clear() }

    private val channel = MethodChannel(messenger, "app.pepehub/audio_folder")
    private val worker = Executors.newSingleThreadExecutor()
    // Availability checks used by playback must not queue behind SAF exports.
    private val playbackChecks = Executors.newFixedThreadPool(2)
    private val main = Handler(Looper.getMainLooper())
    private val allowed = mutableSetOf<String>()
    private val streams = mutableMapOf<String, InputStream>()
    private var pending: MethodChannel.Result? = null
    private var pendingBooks = false
    private var pendingWriteRoot: Uri? = null
    private val bookAccess = BookFileAccess(context)
    private var exportText: String? = null
    @Volatile private var disposed = false
    private val extensions = setOf("mp3", "m4a", "m4b", "aac", "ogg", "opus", "flac", "wav")

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "requestBookWriteAccess") {
                requestBookWriteAccess(call.argument<String>("root") ?: "", result)
            } else if (call.method == "revealBookFile") {
                try {
                    val uri = Uri.parse(call.argument<String>("root") ?: call.argument<String>("uri") ?: error("Нет пути"))
                    val initial = if (Docs.isTreeUri(uri)) Docs.buildDocumentUriUsingTree(uri, Docs.getTreeDocumentId(uri)) else uri
                    val activity = owner.get() ?: error("Откройте приложение")
                    val view = Intent(Intent.ACTION_VIEW).setDataAndType(initial, Docs.Document.MIME_TYPE_DIR).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    try { activity.startActivity(view) }
                    catch (_: android.content.ActivityNotFoundException) {
                        activity.startActivity(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).putExtra(Docs.EXTRA_INITIAL_URI, initial))
                    }
                    result.success(null)
                } catch (e: Exception) { result.error("reveal", "Не удалось открыть папку в файловом менеджере", null) }
            } else if (call.method == "exportStatistics") {
                if (pending != null) result.error("busy", "Закройте текущий выбор файла", null)
                else try {
                    val text = call.argument<String>("text") ?: error("Нет данных")
                    check(text.toByteArray(Charsets.UTF_8).size <= 16 * 1024 * 1024) { "Экспорт больше 16 МиБ. Выберите меньший период." }
                    pending = result
                    exportText = text
                    (owner.get() ?: error("Откройте приложение")).startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = call.argument<String>("mime") ?: "application/json"
                        putExtra(Intent.EXTRA_TITLE, call.argument<String>("name") ?: "statistics.json")
                    }, 4713)
                } catch (e: Exception) { pending = null; exportText = null; result.error("export", e.message, null) }
            } else if (call.method == "pick") {
                if (pending != null) {
                    result.error("busy", "Выбор папки уже открыт", null)
                } else {
                    pendingBooks = call.argument<Boolean>("books") == true
                    pending = result
                    try {
                        (owner.get() ?: error("Откройте приложение")).startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                        }, 4712)
                    } catch (e: Exception) {
                        pending = null
                        result.error("folder", e.message, null)
                    }
                }
            } else if (call.method == "scan") {
                val uri = Uri.parse(call.argument<String>("root") ?: "")
                val permission = context.contentResolver.persistedUriPermissions.firstOrNull { it.uri == uri && it.isReadPermission }
                if (pending != null) result.error("busy", "Дождитесь выбора папки", null)
                else if (permission == null) result.error("permission", "Доступ потерян. Укажите папку заново.", null)
                else {
                    pendingBooks = call.argument<Boolean>("books") == true
                    pending = result
                    onActivityResult(4712, Activity.RESULT_OK, Intent().setData(uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or (if (permission.isWritePermission) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)))
                }
            } else if (call.method in listOf("deleteBookFile", "supportFiles", "open", "read", "close", "exists", "snapshot", "cover", "artwork", "metadata", "readRange", "journal", "readingJournal", "report", "relocate")) {
                work(result, if (call.method == "exists") playbackChecks else worker) {
                    when (call.method) {
                        "deleteBookFile" -> {
                            bookAccess.delete(call.argument<String>("uri") ?: error("Нет URI"),
                                call.argument<String>("hash") ?: error("Нет контрольной суммы"), call.argument<Boolean>("checkOnly") == true)
                            null
                        }
                        "supportFiles" -> {
                            val tree = Uri.parse(call.argument<String>("root") ?: error("Нет корня"))
                            check(context.contentResolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission }) { "Подключите папку заново" }
                            val files = mutableListOf<Map<String, Any>>()
                            fun walk(parent: Uri, prefix: String, depth: Int) {
                                check(depth <= 5) { "Слишком глубокая папка данных" }
                                context.contentResolver.query(Docs.buildChildDocumentsUriUsingTree(parent, Docs.getDocumentId(parent)), arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME, Docs.Document.COLUMN_MIME_TYPE, Docs.Document.COLUMN_SIZE), null, null, null)?.use { cursor ->
                                    while (cursor.moveToNext()) {
                                        val name = cursor.getString(1) ?: continue
                                        if (depth == 0 && name != ".pepehub") continue
                                        val uri = Docs.buildDocumentUriUsingTree(tree, cursor.getString(0))
                                        val path = "$prefix$name"
                                        if (cursor.getString(2) == Docs.Document.MIME_TYPE_DIR) {
                                            if (depth == 0 || name == "reading" || name == "logs" || name.matches(Regex("\\d{4}-\\d{2}-\\d{2}"))) walk(uri, "$path/", depth + 1)
                                        } else if (name.endsWith(".json") || name.endsWith(".json.bak")) {
                                            check(files.size < 10000) { "Слишком много журналов" }
                                            val size = cursor.getLong(3)
                                            if (size in 1..16 * 1024 * 1024) files.add(mapOf("uri" to uri.toString(), "name" to path, "size" to size))
                                        }
                                    }
                                } ?: error("Не удалось прочитать данные папки")
                            }
                            walk(Docs.buildDocumentUriUsingTree(tree, Docs.getTreeDocumentId(tree)), "", 0)
                            files
                        }
                        "relocate" -> {
                            val sourceTree = Uri.parse(call.argument<String>("sourceRoot") ?: error("Нет корня"))
                            val targetTree = Uri.parse(call.argument<String>("targetRoot") ?: error("Нет назначения"))
                            val from = call.argument<String>("source") ?: error("Нет папки")
                            val to = call.argument<String>("target") ?: error("Нет имени")
                            check(sourceTree.authority == targetTree.authority) { "Провайдеры разные: перенос без копирования недоступен" }
                            for (tree in listOf(sourceTree, targetTree)) {
                                check(context.contentResolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission && it.isWritePermission }) { "Нужен доступ к обоим корням на чтение и запись" }
                            }
                            fun parts(path: String): List<String> = if (path.isEmpty()) emptyList() else path.split('/').also { values ->
                                check(values.all { it.isNotEmpty() && it != "." && it != ".." && !it.contains('\\') && !it.equals(".pepehub", true) }) { "Недопустимый путь" }
                            }
                            fun findChild(parent: Uri, name: String): Uri? {
                                val matches = mutableListOf<Uri>()
                                context.contentResolver.query(Docs.buildChildDocumentsUriUsingTree(parent, Docs.getDocumentId(parent)), arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
                                    while (it.moveToNext()) if (it.getString(1).equals(name, true)) matches.add(Docs.buildDocumentUriUsingTree(parent, it.getString(0)))
                                } ?: error("Папка недоступна")
                                check(matches.size <= 1) { "Неоднозначное имя" }
                                return matches.firstOrNull()
                            }
                            fun directory(tree: Uri, path: List<String>): Uri {
                                var uri = Docs.buildDocumentUriUsingTree(tree, Docs.getTreeDocumentId(tree))
                                for (name in path) uri = findChild(uri, name) ?: error("Папка назначения не найдена")
                                check(context.contentResolver.getType(uri) == Docs.Document.MIME_TYPE_DIR) { "Путь не является папкой" }
                                return uri
                            }
                            val sourceParts = parts(from)
                            val targetParts = parts(to)
                            check(sourceParts.isNotEmpty() && targetParts.isNotEmpty()) { "Корень нельзя перемещать" }
                            val source = directory(sourceTree, sourceParts)
                            val sourceParent = directory(sourceTree, sourceParts.dropLast(1))
                            val targetParent = directory(targetTree, targetParts.dropLast(1))
                            check(findChild(targetParent, targetParts.last()) == null) { "Назначение уже существует" }
                            val flags = context.contentResolver.query(source, arrayOf(Docs.Document.COLUMN_FLAGS), null, null, null)?.use { if (it.moveToFirst()) it.getInt(0) else 0 } ?: 0
                            if (Docs.getDocumentId(sourceParent) == Docs.getDocumentId(targetParent)) {
                                check(flags and Docs.Document.FLAG_SUPPORTS_RENAME != 0) { "Провайдер не поддерживает переименование" }
                                Docs.renameDocument(context.contentResolver, source, targetParts.last()) ?: error("Не удалось переименовать")
                            } else {
                                check(sourceParts.last() == targetParts.last()) { "Переименуйте отдельно от переноса" }
                                check(flags and Docs.Document.FLAG_SUPPORTS_MOVE != 0) { "Провайдер не поддерживает перенос без копирования" }
                                check(Docs.getDocumentId(source) != Docs.getDocumentId(targetParent) && !Docs.isChildDocument(context.contentResolver, source, targetParent)) { "Нельзя переместить папку внутрь себя" }
                                Docs.moveDocument(context.contentResolver, source, sourceParent, targetParent) ?: error("Не удалось переместить")
                            }
                            null
                        }
                        "readRange" -> {
                            val uri = Uri.parse(call.argument<String>("uri") ?: error("Нет URI"))
                            val offset = call.argument<Number>("offset")?.toLong() ?: 0L
                            val count = call.argument<Number>("count")?.toInt() ?: 0
                            check(offset >= 0 && count in 0..1048576) { "Некорректный диапазон" }
                            val descriptor = context.contentResolver.openFileDescriptor(uri, "r") ?: error("Файл недоступен")
                            android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
                                input.channel.position(offset)
                                val buffer = ByteArray(count)
                                var total = 0
                                while (total < count) { val n = input.read(buffer, total, count-total); if (n <= 0) break; total += n }
                                buffer.copyOf(total)
                            }
                        }
                        "metadata" -> {
                            val source = Uri.parse(call.argument<String>("uri") ?: error("Нет URI"))
                            check(source.scheme == "content" || source.scheme == "file") { "Нужен локальный файл" }
                            val retriever = android.media.MediaMetadataRetriever()
                            try {
                                if (source.scheme == "file") retriever.setDataSource(source.path ?: error("Нет пути"))
                                else retriever.setDataSource(context, source)
                                val fields = mapOf("title" to 7, "author" to 3, "album" to 1, "genre" to 6, "year" to 8, "composer" to 4, "disc" to 14, "track" to 0, "mimeType" to 12, "writer" to 11, "albumArtist" to 13, "bitrate" to 20, "sampleRate" to 38, "bitsPerSample" to 39, "numberOfTracks" to 10, "date" to 5)
                                val values = mutableMapOf<String, Any>()
                                for ((key, code) in fields) runCatching { retriever.extractMetadata(code) }.getOrNull()?.trim()?.takeIf { it.isNotEmpty() && it.length <= 10000 }?.let { values[key] = it }
                                if (!values.containsKey("author")) retriever.extractMetadata(2)?.trim()?.takeIf { it.isNotEmpty() }?.let { values["author"] = it }
                                retriever.extractMetadata(9)?.toLongOrNull()?.takeIf { it > 0 }?.let { values["durationMs"] = it }
                                values
                            } finally { retriever.release() }
                        }
                        "artwork" -> {
                            val source = Uri.parse(call.argument<String>("uri") ?: error("Нет URI"))
                            var id = Docs.getDocumentId(source).substringBeforeLast('/', "")
                            var bitmap: android.graphics.Bitmap? = null
                            for (level in 0..4) {
                                if (id.isEmpty()) break
                                val images = mutableListOf<Pair<String, Uri>>()
                                context.contentResolver.query(Docs.buildChildDocumentsUriUsingTree(source, id), arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
                                    while (it.moveToNext()) {
                                        val name = it.getString(1).lowercase(java.util.Locale.ROOT)
                                        if (name.substringAfterLast('.') in setOf("jpg", "jpeg", "png", "webp")) {
                                            val rank = listOf("cover", "folder", "front", "обложка").indexOf(name.substringBeforeLast('.')).let { n -> if (n < 0) 9 else n }
                                            images.add("$rank:$name" to Docs.buildDocumentUriUsingTree(source, it.getString(0)))
                                        }
                                    }
                                }
                                for ((_, uri) in images.sortedBy { it.first }) {
                                    bitmap = runCatching {
                                        val options = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                                        context.contentResolver.openInputStream(uri)?.use { android.graphics.BitmapFactory.decodeStream(it, null, options) }
                                        options.inSampleSize = 1
                                        while (options.outWidth / options.inSampleSize > 1024 || options.outHeight / options.inSampleSize > 1024) options.inSampleSize *= 2
                                        options.inJustDecodeBounds = false
                                        context.contentResolver.openInputStream(uri)?.use { android.graphics.BitmapFactory.decodeStream(it, null, options) }
                                    }.getOrNull()
                                    if (bitmap != null) break
                                }
                                if (bitmap != null || !Regex("^(cd|disc|disk|диск|часть|part|том)[-_ .]*[0-9]+$", RegexOption.IGNORE_CASE).matches(id.substringAfterLast('/'))) break
                                id = id.substringBeforeLast('/', "")
                            }
                            if (bitmap == null) {
                                val retriever = android.media.MediaMetadataRetriever()
                                try {
                                    retriever.setDataSource(context, source)
                                    val bytes = retriever.embeddedPicture
                                    if (bytes != null && bytes.size <= 16 * 1024 * 1024) {
                                        val options = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                                        android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
                                        options.inSampleSize = 1
                                        while (options.outWidth / options.inSampleSize > 1024 || options.outHeight / options.inSampleSize > 1024) options.inSampleSize *= 2
                                        options.inJustDecodeBounds = false
                                        bitmap = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
                                    }
                                } finally { retriever.release() }
                            }
                            bitmap?.let { image ->
                                try {
                                    java.io.ByteArrayOutputStream().use { output -> image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output); output.toByteArray() }
                                } finally { image.recycle() }
                            }
                        }
                        "cover" -> {
                            val source = Uri.parse(call.argument<String>("uri") ?: error("Нет URI"))
                            val id = Docs.getDocumentId(source)
                            // External-storage document IDs retain the relative folder path.
                            // Providers without hierarchical IDs simply have no sibling artwork.
                            if (!id.contains('/')) null else {
                                val parent = id.substringBeforeLast('/')
                                val images = mutableListOf<Pair<String, String>>()
                                context.contentResolver.query(Docs.buildChildDocumentsUriUsingTree(source, parent), arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME, Docs.Document.COLUMN_MIME_TYPE), null, null, null)?.use {
                                    while (it.moveToNext()) {
                                        val name = it.getString(1).lowercase(java.util.Locale.ROOT)
                                        if (it.getString(2) != Docs.Document.MIME_TYPE_DIR && name.substringAfterLast('.') in setOf("jpg", "jpeg", "png", "webp")) {
                                            val rank = listOf("cover", "folder", "front", "обложка").indexOf(name.substringBeforeLast('.')).let { n -> if (n < 0) 9 else n }
                                            images.add("$rank:$name" to Docs.buildDocumentUriUsingTree(source, it.getString(0)).toString())
                                        }
                                    }
                                }
                                images.minByOrNull { it.first }?.second
                            }
                        }
                        "snapshot", "journal", "readingJournal", "report" -> {
                            val tree = Uri.parse(call.argument<String>("root") ?: error("Нет папки"))
                            val text = call.argument<String>("json") ?: error("Нет данных")
                            val bytes = text.toByteArray(Charsets.UTF_8)
                            check(bytes.size <= 16 * 1024 * 1024) { "Снимок слишком большой" }
                            check(context.contentResolver.persistedUriPermissions.any { it.uri == tree && it.isWritePermission }) { "Папка доступна только для чтения" }
                            val rootId = Docs.getTreeDocumentId(tree)
                            var support: Uri? = null
                            context.contentResolver.query(Docs.buildChildDocumentsUriUsingTree(tree, rootId), arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME, Docs.Document.COLUMN_MIME_TYPE), null, null, null)?.use {
                                while (it.moveToNext()) if (it.getString(1) == ".pepehub") {
                                    check(it.getString(2) == Docs.Document.MIME_TYPE_DIR) { ".pepehub не является папкой" }
                                    support = Docs.buildDocumentUriUsingTree(tree, it.getString(0))
                                }
                            }
                            var directory = support ?: Docs.createDocument(context.contentResolver, Docs.buildDocumentUriUsingTree(tree, rootId), Docs.Document.MIME_TYPE_DIR, ".pepehub") ?: error("Не удалось создать .pepehub")
                            val finalName = if (call.method == "report") "library.csv" else if (call.method in listOf("journal", "readingJournal")) (call.argument<String>("name") ?: error("Нет имени журнала")) else "library-${System.currentTimeMillis()}-${UUID.randomUUID()}.json"
                            val replace = call.argument<Boolean>("replace") == true || call.method == "report"
                            var existing: Uri? = null
                            var backup: Uri? = null
                            if (call.method in listOf("journal", "readingJournal")) {
                                val day = call.argument<String>("day") ?: error("Нет даты")
                                check(Regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$").matches(day))
                                for (name in (if (call.method == "readingJournal") listOf("reading", "logs", day) else listOf("logs", day))) {
                                    var child: Uri? = null
                                    context.contentResolver.query(Docs.buildChildDocumentsUriUsingTree(directory, Docs.getDocumentId(directory)), arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME, Docs.Document.COLUMN_MIME_TYPE), null, null, null)?.use {
                                        while (it.moveToNext()) if (it.getString(1) == name) { check(it.getString(2) == Docs.Document.MIME_TYPE_DIR); child = Docs.buildDocumentUriUsingTree(directory, it.getString(0)) }
                                    }
                                    directory = child ?: Docs.createDocument(context.contentResolver, directory, Docs.Document.MIME_TYPE_DIR, name) ?: error("Не удалось создать каталог журнала")
                                }
                                check(if (call.method == "readingJournal") finalName == "reading-$day.json" else Regex("^events-([a-f0-9]{64}|[0-9]{4}-[0-9]{2}-[0-9]{2})[.]json$").matches(finalName)) { "Некорректное имя журнала" }
                                var found = false
                                context.contentResolver.query(Docs.buildChildDocumentsUriUsingTree(directory, Docs.getDocumentId(directory)), arrayOf(Docs.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { while (it.moveToNext()) if (it.getString(0) == finalName) found = true }
                                if (found && !replace) return@work null
                            }
                            if (replace) {
                                context.contentResolver.query(Docs.buildChildDocumentsUriUsingTree(directory, Docs.getDocumentId(directory)), arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
                                    while (it.moveToNext()) {
                                        val uri = Docs.buildDocumentUriUsingTree(directory, it.getString(0))
                                        if (it.getString(1) == finalName) existing = uri
                                        if (it.getString(1) == "$finalName.bak") backup = uri
                                    }
                                }
                            }
                            val document = Docs.createDocument(context.contentResolver, directory, if (call.method == "report") "text/csv" else "application/json", "$finalName.partial") ?: error("Не удалось создать снимок")
                            try {
                                (context.contentResolver.openOutputStream(document) ?: error("Не удалось записать снимок")).use { it.write(bytes) }
                                existing?.let { old ->
                                    backup?.let { check(Docs.deleteDocument(context.contentResolver, it)) { "Не удалось заменить резервную копию" } }
                                    Docs.renameDocument(context.contentResolver, old, "$finalName.bak") ?: error("Не удалось сохранить резервную копию")
                                }
                                Docs.renameDocument(context.contentResolver, document, finalName) ?: error("Провайдер не поддерживает завершение снимка")
                            } catch (e: Exception) {
                                runCatching { Docs.deleteDocument(context.contentResolver, document) }
                                throw e
                            }
                            // Remove only old immutable packets whose complete
                            // event payloads are now present in the committed daily file.
                            if (call.method == "journal" && replace) {
                                val covered = mutableMapOf<String, String>()
                                val entries = JSONObject(text).getJSONArray("events")
                                for (i in 0 until entries.length()) {
                                    val event = entries.getJSONObject(i)
                                    covered[event.getString("id")] = event.getJSONObject("data").toString()
                                }
                                val oldPackets = mutableListOf<Uri>()
                                context.contentResolver.query(Docs.buildChildDocumentsUriUsingTree(directory, Docs.getDocumentId(directory)), arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
                                    while (it.moveToNext()) if (Regex("^events-[a-f0-9]{64}[.]json$").matches(it.getString(1))) oldPackets.add(Docs.buildDocumentUriUsingTree(directory, it.getString(0)))
                                }
                                for (old in oldPackets) runCatching {
                                    val raw = context.contentResolver.openInputStream(old)?.use { input ->
                                        val output = java.io.ByteArrayOutputStream()
                                        val buffer = ByteArray(8192)
                                        while (output.size() <= 16 * 1024 * 1024) {
                                            val count = input.read(buffer)
                                            if (count < 0) break
                                            output.write(buffer, 0, count)
                                        }
                                        output.toByteArray()
                                    } ?: return@runCatching
                                    if (raw.size > 16 * 1024 * 1024) return@runCatching
                                    val packet = JSONObject(String(raw, Charsets.UTF_8))
                                    if (packet.optString("kind") != "audio-journal") return@runCatching
                                    val previous = packet.getJSONArray("events")
                                    var safe = previous.length() > 0
                                    for (i in 0 until previous.length()) {
                                        val event = previous.getJSONObject(i)
                                        if (covered[event.getString("id")] != event.getJSONObject("data").toString()) safe = false
                                    }
                                    if (safe) Docs.deleteDocument(context.contentResolver, old)
                                }
                            }
                            val snapshots = mutableListOf<Pair<String, Uri>>()
                            context.contentResolver.query(Docs.buildChildDocumentsUriUsingTree(directory, Docs.getDocumentId(directory)), arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
                                while (it.moveToNext()) {
                                    val name = it.getString(1)
                                    if (Regex("^library-[0-9]+-[a-f0-9-]+[.]json$").matches(name)) snapshots.add(name to Docs.buildDocumentUriUsingTree(directory, it.getString(0)))
                                }
                            }
                            for ((_, old) in snapshots.sortedByDescending { it.first }.drop(10)) Docs.deleteDocument(context.contentResolver, old)
                            null
                        }
                        "exists" -> {
                            val uri = Uri.parse(call.argument<String>("uri") ?: error("Нет URI"))
                            try {
                                context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { true } ?: false
                            } catch (_: Exception) { false }
                        }
                        "open" -> {
                            val uri = call.argument<String>("uri") ?: error("Нет URI")
                            val document = Uri.parse(uri)
                            val tree = if (Docs.isTreeUri(document)) Docs.buildTreeDocumentUri(document.authority, Docs.getTreeDocumentId(document)) else null
                            // Previously selected reading roots must also work after restart
                            // or after scanning another root. The provider enforces ancestry.
                            check(uri in allowed || (tree != null && context.contentResolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission })) { "Доступ к папке потерян. Подключите её заново." }
                            check(streams.size < 4) { "Слишком много открытых файлов" }
                            val input = context.contentResolver.openInputStream(document) ?: error("Не удалось открыть файл")
                            val token = UUID.randomUUID().toString()
                            streams[token] = input
                            token
                        }
                        "read" -> {
                            val input = streams[call.argument<String>("handle")] ?: error("Файл закрыт")
                            val buffer = ByteArray(64 * 1024)
                            val size = input.read(buffer)
                            if (size < 0) ByteArray(0) else buffer.copyOf(size)
                        }
                        else -> {
                            streams.remove(call.argument<String>("handle"))?.close()
                            null
                        }
                    }
                }
            } else result.notImplemented()
        }
    }

    fun requestBookWriteAccess(root: String, result: MethodChannel.Result) {
        if (pending != null) { result.error("busy", "Закройте текущий выбор файла или папки", null); return }
        try {
            val expected = bookAccess.root(root)
            val activity = owner.get() ?: error("Откройте приложение")
            pending = result
            pendingWriteRoot = expected
            activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                putExtra(Docs.EXTRA_INITIAL_URI, Docs.buildDocumentUriUsingTree(expected, Docs.getTreeDocumentId(expected)))
            }, 4714)
        } catch (e: Exception) {
            pending = null; pendingWriteRoot = null
            result.error("book_file", e.message, null)
        }
    }

    private fun work(result: MethodChannel.Result, executor: java.util.concurrent.ExecutorService = worker, operation: () -> Any?) {
        executor.execute {
            try {
                check(!disposed) { "Импорт закрыт" }
                val value = operation()
                main.post {
                    if (disposed) result.error("closed", "Импорт закрыт", null)
                    else result.success(value)
                }
            } catch (e: Exception) {
                main.post {
                    if (e is BookFileAccessFailure) result.error(e.code, e.message, e.root?.let { mapOf("root" to it.toString()) })
                    else result.error("folder", e.message, null)
                }
            }
        }
    }

    fun onActivityResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request == 4714) {
            val result = pending ?: return true
            val expected = pendingWriteRoot ?: return true
            pending = null; pendingWriteRoot = null
            if (code != Activity.RESULT_OK || data?.data == null) result.success(false)
            else work(result) { bookAccess.grant(expected, data.data, data.flags) }
            return true
        }
        if (request == 4713) {
            val result = pending ?: return true
            val text = exportText
            pending = null
            exportText = null
            val uri = data?.data
            if (code != Activity.RESULT_OK || uri == null || text == null) result.success(false)
            else work(result) {
                (context.contentResolver.openOutputStream(uri, "wt") ?: error("Не удалось открыть экспорт")).use { it.write(text.toByteArray(Charsets.UTF_8)) }
                true
            }
            return true
        }
        if (request != 4712) return false
        val result = pending ?: return true
        val books = pendingBooks
        pending = null
        val tree = data?.data
        if (code != Activity.RESULT_OK || tree == null) {
            result.success(null)
            return true
        }
        work(result) {
            streams.values.forEach { it.close() }
            streams.clear()
            allowed.clear()
            val files = mutableListOf<Map<String, Any>>()
            val visited = mutableSetOf<String>()
            var count = 0
            val rootId = Docs.getTreeDocumentId(tree)
            val root = Docs.buildDocumentUriUsingTree(tree, rootId)
            fun completeFolder(cursor: android.database.Cursor) {
                if (cursor.extras.getBoolean(Docs.EXTRA_LOADING, false) || !cursor.extras.getString(Docs.EXTRA_ERROR).isNullOrEmpty())
                    throw BookFileAccessFailure("folder_unavailable", "Папка недоступна или список файлов ещё загружается. Обновите папку позже. Книги сохранены в библиотеке.")
            }
            val title = try {
                (context.contentResolver.query(root, arrayOf(Docs.Document.COLUMN_DISPLAY_NAME, Docs.Document.COLUMN_MIME_TYPE), null, null, null)
                    ?: error("Нет доступа к корню")).use {
                    completeFolder(it)
                    check(it.moveToFirst() && it.getString(1) == Docs.Document.MIME_TYPE_DIR) { "Корень недоступен" }
                    it.getString(0) ?: "Папка"
                }
            } catch (e: BookFileAccessFailure) { throw e }
            catch (e: Exception) { throw BookFileAccessFailure("folder_unavailable", "Не удалось открыть папку. Проверьте доступ и подключение накопителя. Книги сохранены в библиотеке.") }
            // Query one directory at a time. Some document providers cannot
            // serve a child query while the parent cursor is still open.
            val folders = java.util.ArrayDeque<Triple<String, String, Int>>()
            folders.add(Triple(rootId, "", 0))
            while (folders.isNotEmpty()) {
                check(!disposed) { "Импорт закрыт" }
                val (id, prefix, depth) = folders.removeFirst()
                check(depth <= 32) { "Слишком много вложенных папок (максимум 32)" }
                if (!visited.add(id)) continue
                val children = Docs.buildChildDocumentsUriUsingTree(tree, id)
                val columns = arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME,
                    Docs.Document.COLUMN_MIME_TYPE, Docs.Document.COLUMN_SIZE)
                val cursor = context.contentResolver.query(children, columns, null, null, null) ?: error("Папка недоступна: $prefix")
                cursor.use {
                    completeFolder(it)
                    while (it.moveToNext()) {
                        check(!disposed) { "Импорт закрыт" }
                        check(++count <= 50000) { "Слишком большая папка (максимум 50000 элементов)" }
                        val childId = it.getString(0)
                        val name = it.getString(1).replace('/', '_').replace('\\', '_')
                        val relative = if (prefix.isEmpty()) name else "$prefix/$name"
                        if (it.getString(2) == Docs.Document.MIME_TYPE_DIR) {
                            if (name.lowercase() != ".pepehub" && !name.lowercase().startsWith("!smart audiobook player")) {
                                folders.add(Triple(childId, relative, depth + 1))
                            }
                        } else if (name.substringAfterLast('.', "").lowercase() in (if (books) setOf("epub", "fb2", "zip", "txt", "md", "markdown", "html", "htm", "xhtml", "docx", "pdf", "rtf") else extensions)) {
                            val uri = Docs.buildDocumentUriUsingTree(tree, childId).toString()
                            files.add(mapOf("uri" to uri, "name" to relative, "size" to if (it.isNull(3)) -1L else it.getLong(3)))
                            check(files.size <= 10000) { "В выбранной папке допускается не более 10000 файлов" }
                        }
                    }
                }
            }
            // Fail visibly when the provider cannot retain read access.
            val granted = (data?.flags ?: 0) and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            context.contentResolver.takePersistableUriPermission(tree, granted)
            allowed.addAll(files.map { it["uri"] as String })
            mapOf("title" to title, "files" to files, "root" to tree.toString())
        }
        return true
    }

    fun dispose() {
        disposed = true
        playbackChecks.shutdownNow()
        channel.setMethodCallHandler(null)
        pending?.error("closed", "Выбор папки закрыт", null)
        pending = null
        worker.execute {
            streams.values.forEach { runCatching { it.close() } }
            streams.clear()
            allowed.clear()
        }
        worker.shutdown()
    }
}
