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
import android.os.ParcelFileDescriptor
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors

/** Direct sync sees only explicitly granted SAF trees. All provider IO runs off the UI thread. */
class PeerFilesChannel(contextSource: android.content.Context, messenger: BinaryMessenger) {
    private val context = contextSource.applicationContext
    private val resolver = context.contentResolver
    private var owner = java.lang.ref.WeakReference(contextSource as? Activity)
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
    private fun scan(tree: Uri, call: MethodCall): List<Map<String, Any>> {
        val cached = call.argument<Map<String, Map<String, Any?>>>("cached") ?: emptyMap()
        val invalidated = call.argument<List<String>>("invalidated")?.toSet() ?: emptySet()
        val force = call.argument<Boolean>("forceHash") == true
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
                        val stamp = "${Docs.getDocumentId(item.uri)}:${item.modified}"
                        val old = cached[relative]
                        val reuse = !force && relative !in invalidated && item.modified > 0 && item.bytes >= 0 &&
                            old?.get("stamp") == stamp && (old["bytes"] as? Number)?.toLong() == item.bytes &&
                            (old["hash"] as? String)?.matches(Regex("[a-f0-9]{64}")) == true
                        val (hash, size) = if (reuse) (old!!["hash"] as String) to item.bytes else digest(item.uri)
                        val after = node(tree, item.uri)
                        check(item.bytes == after.bytes && item.modified == after.modified) { "Файл меняется во время сканирования" }
                        files.add(mapOf("path" to relative, "hash" to hash, "bytes" to size, "stamp" to stamp))
                        check(files.size <= 10000) { "Больше 10000 файлов" }
                    }
                }
            }
        }
        visit(root(tree), "", 0); return files
    }
    private data class HistoryPolicy(val enabled: Boolean, val days: Int, val bytes: Long)
    private fun historyPolicy(call: MethodCall): HistoryPolicy {
        val value = call.argument<Map<String, Any?>>("history") ?: emptyMap()
        val policy = HistoryPolicy(value["enabled"] == true,
            (value["maxDays"] as? Number)?.toInt() ?: 30,
            (value["maxBytes"] as? Number)?.toLong() ?: 500L * 1024 * 1024)
        check(policy.days in 1..3650 && policy.bytes in 1..(1L shl 40)) { "Некорректные ограничения истории" }
        return policy
    }
    private fun historyTime(name: String): Long? {
        for (pattern in listOf("^v1-(\\d{13})-[a-f0-9]{32}-.+$",
            "^\\.pepehub-version-(\\d{13})-[a-f0-9]{8}-.+$", "^(\\d{16})-[a-f0-9]{12}-.+$")) {
            val digits = Regex(pattern).matchEntire(name)?.groupValues?.get(1) ?: continue
            return digits.toLong() / if (digits.length == 16) 1000 else 1
        }
        return null
    }
    private data class Archived(val uri: Uri, val parent: Uri)
    private data class HistoryItem(val node: Node, val time: Long, val legacy: Boolean)
    private inner class History(val tree: Uri, val policy: HistoryPolicy) {
        val warnings = mutableListOf<String>()
        fun directory(create: Boolean, leaf: String = "versions"): Uri? {
            var current = root(tree)
            for (name in listOf(".pepehub", "p2p", leaf)) {
                val matches = children(tree, current).filter { it.name.equals(name, ignoreCase = true) }
                check(matches.size <= 1 && matches.none { it.name != name || !it.directory }) { "Служебная папка истории недоступна" }
                current = matches.firstOrNull()?.uri ?: if (create) {
                    Docs.createDocument(resolver, current, Docs.Document.MIME_TYPE_DIR, name) ?: error("История не создана")
                } else return null
            }
            return current
        }
        fun archive(existing: Uri, parent: Uri, original: String, pending: Boolean = false): Archived {
            val versions = directory(true)!!
            // Cleanup only sees committed versions. Active rollback documents
            // remain outside that directory until the new file is published.
            val destination = if (pending) directory(true, "transactions")!! else versions
            val name = "v1-${System.currentTimeMillis()}-${UUID.randomUUID().toString().replace("-", "")}-${original.take(140)}"
            val renamed = Docs.renameDocument(resolver, existing, name) ?: error("Не удалось сохранить предыдущую версию")
            try {
                val moved = Docs.moveDocument(resolver, renamed, parent, destination)
                    ?: error("Провайдер не поддерживает перемещение истории. Отключите сохранение версий")
                return Archived(moved, destination)
            } catch (e: Exception) {
                if (children(tree, parent).none { it.name == original }) {
                    try { Docs.renameDocument(resolver, renamed, original) } catch (_: Exception) { /* Keep the recoverable document. */ }
                }
                throw e
            }
        }
        fun restore(archived: Archived, parent: Uri, original: String) {
            if (children(tree, parent).any { it.name == original }) return
            val current = if (archived.parent == parent) archived.uri else
                Docs.moveDocument(resolver, archived.uri, archived.parent, parent) ?: error("Не удалось вернуть предыдущую версию из истории")
            check(Docs.renameDocument(resolver, current, original) != null) { "Не удалось восстановить имя предыдущей версии" }
        }
        fun commit(archived: Archived) {
            try {
                check(Docs.moveDocument(resolver, archived.uri, archived.parent, directory(true)!!) != null) { "Провайдер не перенёс предыдущую версию в историю" }
            } catch (e: Exception) {
                warnings.add("Предыдущая версия осталась в служебной папке transactions: ${e.message}")
            }
        }
        fun pruneAfterCommit() {
            if (!policy.enabled) return
            try { maintain(false, true, false) }
            catch (e: Exception) { warnings.add("Не применены ограничения истории: ${e.message}") }
        }
        fun maintain(migrate: Boolean, prune: Boolean, clear: Boolean): Map<String, Any> {
            val items = mutableListOf<HistoryItem>()
            var moved = 0; var unknown = 0; var removed = 0; var reclaimed = 0L
            directory(false)?.let { dir ->
                children(tree, dir).forEach {
                    val time = historyTime(it.name)
                    if (!it.directory && time != null) items.add(HistoryItem(it, time, false)) else unknown++
                }
            }
            if (migrate || clear) {
                val seen = mutableSetOf<String>(); var visited = 0
                var migrationDirectory: Uri? = null
                val reserved = mutableSetOf<String>()
                fun visit(parent: Uri, depth: Int) {
                    check(depth <= 32 && seen.add(Docs.getDocumentId(parent))) { "Циклическая или слишком глубокая папка" }
                    for (entry in children(tree, parent)) {
                        check(++visited <= 50000) { "Больше 50000 элементов папки" }
                        val old = Regex("^\\.pepehub-version-\\d{13}-[a-f0-9]{8}-.+$").matches(entry.name)
                        if (old && !entry.directory) {
                            var item = entry; var outside = true
                            if (migrate && !clear) {
                                try {
                                    val destination = migrationDirectory ?: directory(true)!!.also {
                                        migrationDirectory = it
                                        reserved.addAll(children(tree, it).map { child -> child.name.lowercase() })
                                    }
                                    check(entry.name.lowercase() !in reserved) { "Имя истории уже занято" }
                                    val uri = Docs.moveDocument(resolver, entry.uri, parent, destination)
                                        ?: error("Провайдер не поддерживает перемещение истории")
                                    item = node(tree, uri); outside = false; moved++; reserved.add(item.name.lowercase())
                                } catch (e: Exception) { warnings.add("Не перенесена копия ${entry.name}: ${e.message}") }
                            }
                            items.add(HistoryItem(item, historyTime(entry.name)!!, outside))
                        } else if (entry.directory && !ignored(entry.name)) visit(entry.uri, depth + 1)
                    }
                }
                visit(root(tree), 0)
            }
            items.sortWith(compareBy<HistoryItem> { it.time }.thenBy { it.node.name })
            var total = items.filter { !it.legacy }.sumOf { it.node.bytes }
            val cutoff = System.currentTimeMillis() - policy.days * 86_400_000L
            val remaining = mutableListOf<HistoryItem>()
            for (item in items) {
                if (clear || prune && policy.enabled && !item.legacy && (item.time < cutoff || total > policy.bytes)) {
                    try {
                        check(Docs.deleteDocument(resolver, item.node.uri)) { "Провайдер отказал в удалении" }
                        if (!item.legacy) total -= item.node.bytes
                        removed++; reclaimed += item.node.bytes; continue
                    } catch (e: Exception) { warnings.add("Не удалена копия ${item.node.name}: ${e.message}") }
                }
                remaining.add(item)
            }
            return mapOf("files" to remaining.size, "bytes" to remaining.sumOf { it.node.bytes },
                "legacy" to remaining.count { it.legacy }, "unknown" to unknown,
                "moved" to moved, "removed" to removed, "reclaimed" to reclaimed, "warnings" to warnings.take(20))
        }
    }
    private fun execute(call: MethodCall): Any? {
        val tree = tree(call.argument<String>("root") ?: error("Нет папки"))
        if (call.method == "check") return null
        if (call.method == "history") return History(tree, historyPolicy(call)).maintain(
            call.argument<Boolean>("migrate") == true, call.argument<Boolean>("prune") == true,
            call.argument<Boolean>("clear") == true)
        if (call.method == "scan") return scan(tree, call)
        if (call.method == "overlaps") {
            val other = tree(call.argument<String>("other") ?: error("Нет папки"))
            if (tree.authority != other.authority) return false
            return Docs.getTreeDocumentId(tree) == Docs.getTreeDocumentId(other) ||
                Docs.isChildDocument(resolver, root(tree), root(other)) || Docs.isChildDocument(resolver, root(other), root(tree))
        }
        if (call.method.startsWith("stage_")) return stage(tree, call)
        val parts = path(call.argument<String>("path") ?: error("Нет пути"))
        val existing = resolve(tree, parts)
        when (call.method) {
            "locate" -> return existing?.toString()
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
            "remove" -> {
                val expected = call.argument<String>("expected")
                check(existing?.let { digest(it).first } == expected) { "Локальный файл изменился во время передачи" }
                val history = History(tree, historyPolicy(call))
                if (existing != null) {
                    if (history.policy.enabled) {
                        history.archive(existing, resolve(tree, parts.dropLast(1))!!, parts.last())
                        history.pruneAfterCommit()
                    } else check(Docs.deleteDocument(resolver, existing)) { "Провайдер не удалил файл" }
                }
                return mapOf("warnings" to history.warnings)
            }
            else -> error("Неизвестная операция")
        }
    }
    /** Chunks are written directly into the chosen SAF folder. The hidden part
     * is renamed after validation; no full payload enters app-private storage. */
    private fun stage(tree: Uri, call: MethodCall): Any? {
        val parts = path(call.argument<String>("path") ?: error("Нет пути"))
        val key = call.argument<String>("stage") ?: error("Нет временного файла")
        check(Regex("[a-f0-9]{64}-[a-f0-9]{64}").matches(key)) { "Неверное имя докачки" }
        val pathHash = MessageDigest.getInstance("SHA-256").digest(parts.joinToString("/").toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
        check(key.substringBefore('-') == pathHash) { "Докачка относится к другому пути" }
        val name = ".pepehub-transfer-$key.part"
        val parent = resolve(tree, parts.dropLast(1), true)!!
        val matches = children(tree, parent).filter { it.name.equals(name, ignoreCase = true) }
        check(matches.size <= 1 && matches.none { it.directory || it.name != name }) { "Неоднозначный временный файл" }
        var temporary = matches.firstOrNull()?.uri
        if (call.method == "stage_discard") {
            if (temporary != null) check(Docs.deleteDocument(resolver, temporary)) { "Докачка не удалена" }
            return null
        }
        if (temporary == null) {
            check(call.method == "stage_prepare") { "Докачка недоступна; повторите обмен" }
            temporary = Docs.createDocument(resolver, parent, "application/octet-stream", name) ?: error("Не удалось создать докачку в общей папке")
            check(node(tree, temporary).name == name) { "Провайдер изменил имя докачки" }
        }
        val part = temporary
        when (call.method) {
            "stage_prepare" -> {
                val descriptor = resolver.openFileDescriptor(part, "r") ?: error("Докачка недоступна")
                descriptor.use {
                    check(it.statSize >= 0) { "Провайдер папки не поддерживает прямую докачку" }
                    return it.statSize
                }
            }
            "stage_reset" -> {
                (resolver.openOutputStream(part, "wt") ?: error("Не удалось очистить докачку")).use { it.flush() }
                return null
            }
            "stage_append" -> {
                val offset = call.argument<Number>("offset")!!.toLong()
                val bytes = call.argument<ByteArray>("bytes")!!
                check(offset >= 0 && bytes.size in 1..256*1024)
                val descriptor = resolver.openFileDescriptor(part, "rw") ?: error("Нет прямого доступа для записи в папку")
                ParcelFileDescriptor.AutoCloseOutputStream(descriptor).use { out ->
                    val channel = out.channel
                    check(channel.size() == offset) { "Смещение докачки изменилось" }
                    channel.position(offset)
                    val buffer = ByteBuffer.wrap(bytes)
                    while (buffer.hasRemaining()) channel.write(buffer)
                }
                return null
            }
            "stage_hash" -> return digest(part).first
            "stage_publish" -> {
                check(digest(part).first == key.substringAfter('-')) { "Докачка изменилась до публикации" }
                val expected = call.argument<String>("expected")
                val existing = resolve(tree, parts)
                check(existing?.let { digest(it).first } == expected) { "Локальный файл изменился во время передачи" }
                val history = History(tree, historyPolicy(call))
                var backup: Archived? = null
                try {
                    if (existing != null) {
                        backup = if (history.policy.enabled) history.archive(existing, parent, parts.last(), pending = true) else {
                            val name = ".pepehub-rollback-${System.currentTimeMillis()}-${UUID.randomUUID().toString().take(8)}-${parts.last().take(140)}"
                            Archived(Docs.renameDocument(resolver, existing, name) ?: error("Провайдер не поддерживает безопасную замену"), parent)
                        }
                    }
                    if (backup != null) check(digest(backup.uri).first == expected) { "Локальный файл изменился во время замены" }
                    val published = Docs.renameDocument(resolver, part, parts.last()) ?: error("Провайдер не поддерживает публикацию файла")
                    check(node(tree, published).name == parts.last()) { "Провайдер изменил имя файла" }
                } catch (e: Exception) {
                    if (backup != null) {
                        try { history.restore(backup, parent, parts.last()) } catch (_: Exception) { /* Retain the recoverable backup. */ }
                    }
                    throw e
                }
                if (backup != null) {
                    if (history.policy.enabled) history.commit(backup) else {
                        try { check(Docs.deleteDocument(resolver, backup.uri)) { "Провайдер не удалил временную версию" } }
                        catch (e: Exception) { history.warnings.add("Не убран временный файл замены: ${e.message}") }
                    }
                }
                history.pruneAfterCommit()
                return mapOf("warnings" to history.warnings)
            }
            else -> error("Неизвестная операция докачки")
        }
    }
    fun dispose() { disposed = true; pending?.error("closed", "Соединение закрыто", null); pending = null; channel.setMethodCallHandler(null); worker.shutdown() }
}
