package app.pepehub.pepehub

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract as Docs
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors

/** Direct sync sees only explicitly granted SAF trees. All provider IO runs off the UI thread. */
class PeerFilesChannel(activity: Activity, messenger: BinaryMessenger) {
    private val context = activity.applicationContext
    private val resolver = context.contentResolver
    private var owner = java.lang.ref.WeakReference(activity)
    private val channel = MethodChannel(messenger, "app.pepehub/peer_files")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pending: MethodChannel.Result? = null
    @Volatile private var disposed = false
    private val requestCode = 4781
    fun attach(activity: Activity) { owner = java.lang.ref.WeakReference(activity) }
    fun detach(activity: Activity) { if (owner.get() === activity) owner.clear() }
    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "pick") {
                try {
                    check(pending == null) { "Выбор папки уже открыт" }
                    pending = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                    @Suppress("DEPRECATION")
                    (owner.get() ?: error("Откройте приложение")).startActivityForResult(intent, requestCode)
                } catch (e: Exception) { pending = null; result.error("folder", e.message, null) }
            } else worker.execute {
                try {
                    check(!disposed)
                    val answer = execute(call)
                    main.post { if (!disposed) result.success(answer) }
                } catch (e: Exception) { main.post { if (!disposed) result.error("peer_files", e.message, null) } }
            }
        }
    }
    fun onActivityResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != requestCode) return false
        val result = pending; pending = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) { result?.success(null); return true }
        try {
            val uri = data.data!!
            val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            check(flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0 && flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0) {
                "Для общей папки нужны чтение и запись"
            }
            resolver.takePersistableUriPermission(uri, flags)
            result?.success(mapOf("root" to uri.toString()))
        } catch (e: Exception) { result?.error("folder", e.message, null) }
        return true
    }
    private data class Node(val uri: Uri, val name: String, val directory: Boolean, val bytes: Long, val modified: Long)
    private val projection = arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME,
        Docs.Document.COLUMN_MIME_TYPE, Docs.Document.COLUMN_SIZE, Docs.Document.COLUMN_LAST_MODIFIED)
    private fun node(tree: Uri, uri: Uri): Node {
        resolver.query(uri, projection, null, null, null)?.use { c ->
            check(c.moveToFirst()) { "Общая папка недоступна" }
            return Node(uri, c.getString(1), c.getString(2) == Docs.Document.MIME_TYPE_DIR, c.getLong(3), c.getLong(4))
        }
        error("Документ недоступен: ${tree.authority}")
    }
    private fun tree(value: String): Uri {
        val uri = Uri.parse(value)
        check(uri.scheme == "content" && Docs.isTreeUri(uri)) { "Выберите папку через системный диалог" }
        check(resolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission && it.isWritePermission }) {
            "Переподключите общую папку: доступ отозван"
        }
        check(node(uri, Docs.buildDocumentUriUsingTree(uri, Docs.getTreeDocumentId(uri))).directory)
        return uri
    }
    private fun root(tree: Uri) = Docs.buildDocumentUriUsingTree(tree, Docs.getTreeDocumentId(tree))
    private fun children(tree: Uri, parent: Uri): List<Node> {
        val result = mutableListOf<Node>()
        resolver.query(Docs.buildChildDocumentsUriUsingTree(tree, Docs.getDocumentId(parent)), projection, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                check(result.size < 50000) { "Слишком много элементов" }
                result.add(Node(Docs.buildDocumentUriUsingTree(tree, c.getString(0)), c.getString(1),
                    c.getString(2) == Docs.Document.MIME_TYPE_DIR, c.getLong(3), c.getLong(4)))
            }
        } ?: error("Не удалось прочитать папку")
        return result
    }
    private fun ignored(name: String): Boolean {
        val n = name.lowercase()
        return n == ".pepehub" || n.startsWith(".pepehub-") || n.startsWith(".syncthing.") ||
            n.startsWith("~syncthing~") || n in setOf("desktop.ini", "thumbs.db", ".ds_store")
    }
    private fun path(value: String): List<String> {
        val parts = value.split('/')
        check(value.isNotEmpty() && value.length <= 1024 && parts.size <= 32 && parts.none {
            it.isEmpty() || it == "." || it == ".." || it.length > 240 || it.endsWith('.') || it.endsWith(' ') ||
                ignored(it) || it.any { ch -> ch.code < 32 || ch.code == 127 || ch in "<>:\"\\|?*" } ||
                Regex("^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])( *\\.| *$)", RegexOption.IGNORE_CASE).containsMatchIn(it)
        }) { "Недопустимый относительный путь" }
        return parts
    }
    private fun resolve(tree: Uri, parts: List<String>, create: Boolean = false): Uri? {
        var current = root(tree)
        parts.forEachIndexed { index, name ->
            val matches = children(tree, current).filter { it.name.equals(name, ignoreCase = true) }
            check(matches.size <= 1 && matches.none { it.name != name }) { "Конфликт регистра имён" }
            val child = matches.firstOrNull()
            if (child == null) {
                if (!create) return null
                current = Docs.createDocument(resolver, current, Docs.Document.MIME_TYPE_DIR, name) ?: error("Папка не создана")
            } else {
                if (index < parts.lastIndex || create) check(child.directory) { "Родительский путь занят файлом" }
                current = child.uri
            }
        }
        return current
    }
    private fun digest(uri: Uri): Pair<String, Long> {
        val hash = MessageDigest.getInstance("SHA-256"); var size = 0L
        (resolver.openInputStream(uri) ?: error("Файл недоступен")).use { stream ->
            val buffer = ByteArray(256 * 1024)
            while (true) { val n = stream.read(buffer); if (n < 0) break; if (n > 0) { hash.update(buffer, 0, n); size += n } }
        }
        return hash.digest().joinToString("") { "%02x".format(it) } to size
    }
    private fun scan(tree: Uri): List<Map<String, Any>> {
        val files = mutableListOf<Map<String, Any>>(); val seen = mutableSetOf<String>(); val folded = mutableSetOf<String>(); var count = 0
        fun visit(parent: Uri, prefix: String, depth: Int) {
            check(depth <= 32 && seen.add(Docs.getDocumentId(parent))) { "Слишком глубокая или циклическая папка" }
            children(tree, parent).forEach { item ->
                check(++count <= 50000) { "Больше 50000 элементов" }
                if (!ignored(item.name)) {
                    val relative = prefix + item.name; path(relative)
                    check(folded.add(relative.lowercase())) { "Конфликт регистра имён" }
                    if (item.directory) visit(item.uri, "$relative/", depth + 1)
                    else {
                        val (hash, size) = digest(item.uri); val after = node(tree, item.uri)
                        check(item.bytes == after.bytes && item.modified == after.modified) { "Файл меняется во время сканирования" }
                        files.add(mapOf("path" to relative, "hash" to hash, "bytes" to size))
                        check(files.size <= 10000) { "Больше 10000 файлов" }
                    }
                }
            }
        }
        visit(root(tree), "", 0); return files
    }
    private fun execute(call: MethodCall): Any? {
        val tree = tree(call.argument<String>("root") ?: error("Нет папки"))
        if (call.method == "scan") return scan(tree)
        if (call.method == "overlaps") {
            val other = tree(call.argument<String>("other") ?: error("Нет папки"))
            if (tree.authority != other.authority) return false
            return Docs.getTreeDocumentId(tree) == Docs.getTreeDocumentId(other) ||
                Docs.isChildDocument(resolver, root(tree), root(other)) || Docs.isChildDocument(resolver, root(other), root(tree))
        }
        val parts = path(call.argument<String>("path") ?: error("Нет пути"))
        val versionName = ".pepehub-version-${System.currentTimeMillis()}-${UUID.randomUUID().toString().take(8)}-${parts.last().take(140)}"
        val existing = resolve(tree, parts)
        when (call.method) {
            "hash" -> return existing?.let { digest(it).first }
            "read" -> {
                val offset = call.argument<Number>("offset")!!.toLong(); val count = call.argument<Int>("count")!!
                check(offset >= 0 && count in 1..256*1024 && existing != null)
                (resolver.openInputStream(existing) ?: error("Файл недоступен")).use { stream ->
                    var remaining = offset
                    while (remaining > 0) { val skipped = stream.skip(remaining); if (skipped > 0) remaining -= skipped else { check(stream.read() >= 0); remaining-- } }
                    val buffer = ByteArray(count); var read = 0
                    while (read < count) { val n = stream.read(buffer, read, count-read); if (n < 0) break; read += n }
                    return buffer.copyOf(read)
                }
            }
            "publish", "remove" -> {
                val expected = call.argument<String>("expected")
                check(existing?.let { digest(it).first } == expected) { "Локальный файл изменился во время передачи" }
                if (call.method == "remove") {
                    if (existing != null) check(Docs.renameDocument(resolver, existing, versionName) != null)
                    return null
                }
                val source = File(call.argument<String>("source") ?: error("Нет временного файла")).canonicalFile
                check(source.isFile && source.path.startsWith(File(context.applicationInfo.dataDir).canonicalPath + File.separator)) { "Нет временного файла приложения" }
                val parent = resolve(tree, parts.dropLast(1), true)!!
                var temporary = Docs.createDocument(resolver, parent, "application/octet-stream", ".pepehub-transfer-${UUID.randomUUID()}") ?: error("Файл не создан")
                var backup: Uri? = null
                try {
                    (resolver.openOutputStream(temporary, "wt") ?: error("Файл недоступен для записи")).use { out -> source.inputStream().use { it.copyTo(out) } }
                    check(digest(temporary).first == source.inputStream().use { input ->
                        val hash = MessageDigest.getInstance("SHA-256"); val buffer = ByteArray(256*1024)
                        while (true) { val n = input.read(buffer); if (n < 0) break; hash.update(buffer, 0, n) }
                        hash.digest().joinToString("") { "%02x".format(it) }
                    }) { "Не совпала контрольная сумма записи" }
                    check(existing?.let { digest(it).first } == expected) { "Локальный файл изменился" }
                    if (existing != null) backup = Docs.renameDocument(resolver, existing, versionName) ?: error("Провайдер не поддерживает сохранение предыдущей версии")
                    temporary = Docs.renameDocument(resolver, temporary, parts.last()) ?: error("Провайдер не поддерживает публикацию файла")
                    check(node(tree, temporary).name == parts.last()) { "Провайдер изменил имя файла" }
                } catch (e: Exception) {
                    if (backup != null && children(tree, parent).none { it.name == parts.last() }) {
                        try { Docs.renameDocument(resolver, backup, parts.last()) } catch (_: Exception) { /* Backup remains recoverable. */ }
                    }
                    throw e
                }
                return null
            }
            else -> error("Неизвестная операция")
        }
    }
    fun dispose() { disposed = true; pending?.error("closed", "Соединение закрыто", null); pending = null; channel.setMethodCallHandler(null); worker.shutdown() }
}
