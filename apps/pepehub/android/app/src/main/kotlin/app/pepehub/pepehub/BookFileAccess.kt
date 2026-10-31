package app.pepehub.pepehub

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract as Docs
import java.security.MessageDigest

class BookFileAccessFailure(val code: String, message: String, val root: Uri? = null) : Exception(message)

/** Uses the granted document/tree URI, including a newer grant on an ancestor.
 * The provider validates tree membership again on query/open/delete. */
class BookFileAccess(private val context: Context) {
    private val resolver get() = context.contentResolver
    private val modes = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION

    private fun treeRoot(uri: Uri): Uri? = if (uri.scheme == "content" && Docs.isTreeUri(uri))
        Docs.buildTreeDocumentUri(uri.authority, Docs.getTreeDocumentId(uri)) else null

    fun root(value: String): Uri = treeRoot(Uri.parse(value))
        ?: throw BookFileAccessFailure("book_file", "Не удалось определить папку книги. Подключите её заново в разделе «Папки книг».")

    fun grant(expected: Uri, selected: Uri?, flags: Int): Boolean {
        if (selected == null) return false
        if (treeRoot(selected) != expected) throw BookFileAccessFailure("book_file", "Выбрана другая папка. Выберите ту же папку, в которой находится книга.")
        if (flags and modes != modes) throw BookFileAccessFailure("book_file", "Хранилище предоставило только чтение. Для удаления нужен доступ на запись.")
        resolver.takePersistableUriPermission(expected, modes)
        return true
    }

    private fun writableDocument(uri: Uri): Uri? {
        val id = Docs.getDocumentId(uri)
        for (permission in resolver.persistedUriPermissions) {
            val granted = permission.uri
            if (!permission.isWritePermission || !permission.isReadPermission || granted.authority != uri.authority) continue
            if (!Docs.isTreeUri(granted)) {
                if (runCatching { Docs.getDocumentId(granted) == id }.getOrDefault(false)) return granted
                continue
            }
            val parentId = Docs.getTreeDocumentId(granted)
            // A file operation must never target the granted directory itself.
            if (parentId == id) continue
            val document = Docs.buildDocumentUriUsingTree(granted, id)
            if (treeRoot(uri) == treeRoot(granted) || runCatching {
                // DocumentsContract.isChildDocument is only public since API 29.
                // A tree-scoped query is available on older Android too; the
                // DocumentsProvider enforces membership before returning rows.
                resolver.query(document, arrayOf(Docs.Document.COLUMN_DOCUMENT_ID), null, null, null)?.use {
                    it.moveToFirst() && it.getString(0) == id
                } == true
            }.getOrDefault(false)) return document
        }
        return null
    }

    private fun denied(uri: Uri): BookFileAccessFailure = BookFileAccessFailure(
        "book_write_permission", "Android разрешил читать книгу, но не удалять её. Предоставьте доступ к её папке.", treeRoot(uri))

    /** A provider can throw while checking membership of an already gone file.
     * Only a complete, readable tree listing can establish absence; an offline
     * device, a null cursor or a loading cloud directory cannot. No payloads
     * are opened or hashed by this fallback. */
    private fun confirmedAbsent(source: Uri): Boolean {
        val tree = treeRoot(source) ?: return false
        if (resolver.persistedUriPermissions.none { it.isReadPermission && treeRoot(it.uri) == tree }) return false
        val target = Docs.getDocumentId(source)
        val rootId = Docs.getTreeDocumentId(tree)
        if (target == rootId) return false
        try {
            fun complete(cursor: android.database.Cursor) {
                check(!cursor.extras.getBoolean(Docs.EXTRA_LOADING, false) && cursor.extras.getString(Docs.EXTRA_ERROR).isNullOrEmpty()) { "Неполный список папки" }
            }
            fun checkRoot() {
                val root = Docs.buildDocumentUriUsingTree(tree, rootId)
                (resolver.query(root, arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_MIME_TYPE), null, null, null)
                    ?: error("Нет доступа к корню")).use {
                    complete(it)
                    check(it.moveToFirst() && it.getString(0) == rootId && it.getString(1) == Docs.Document.MIME_TYPE_DIR) { "Корень недоступен" }
                }
            }
            checkRoot()
            val pending = java.util.ArrayDeque<Pair<String, Int>>()
            val seen = mutableSetOf<String>(); var checked = 0
            pending.add(rootId to 0)
            while (pending.isNotEmpty()) {
                val (parent, depth) = pending.removeFirst()
                check(depth <= 32) { "Слишком глубокая папка" }
                if (!seen.add(parent)) continue
                val children = Docs.buildChildDocumentsUriUsingTree(tree, parent)
                (resolver.query(children, arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_MIME_TYPE), null, null, null)
                    ?: error("Нет списка папки")).use {
                    complete(it)
                    while (it.moveToNext()) {
                        check(++checked <= 50000) { "Слишком большая папка" }
                        val id = it.getString(0)
                        if (id == target) return false
                        if (it.getString(1) == Docs.Document.MIME_TYPE_DIR) pending.add(id to depth + 1)
                    }
                }
            }
            checkRoot()
            return true
        } catch (e: Exception) {
            throw BookFileAccessFailure("book_file", "Не удалось проверить папку книги. Убедитесь, что накопитель подключён и доступ к папке сохранён, затем обновите список.")
        }
    }

    fun delete(uriText: String, expected: String, checkOnly: Boolean) {
        val source = Uri.parse(uriText)
        val linkedBytes = expected.removePrefix("external:").toLongOrNull()
            ?.takeIf { expected.startsWith("external:") && it > 0 }
        check(source.scheme == "content" && (linkedBytes != null || expected.matches(Regex("[a-f0-9]{64}")))) { "Недопустимый источник книги" }
        val uri = writableDocument(source) ?: run {
            if (confirmedAbsent(source)) return
            throw denied(source)
        }
        try {
            val exists = resolver.query(uri, arrayOf(Docs.Document.COLUMN_MIME_TYPE, Docs.Document.COLUMN_FLAGS, Docs.Document.COLUMN_SIZE), null, null, null)?.use { cursor ->
                if (!cursor.moveToFirst()) false else {
                    if (cursor.getString(0) == Docs.Document.MIME_TYPE_DIR)
                        throw BookFileAccessFailure("book_file", "Удаление папки запрещено")
                    if (!cursor.isNull(1) && cursor.getInt(1) and Docs.Document.FLAG_SUPPORTS_DELETE == 0)
                        throw BookFileAccessFailure("book_file", "Хранилище не поддерживает удаление этого файла. Удалите его через файловый менеджер или уберите книгу из списка.")
                    if (linkedBytes != null && (cursor.isNull(2) || cursor.getLong(2) != linkedBytes))
                        throw BookFileAccessFailure("book_file", "Размер аудиофайла изменился. Обновите папку аудиокниг перед удалением.")
                    true
                }
            } ?: false
            if (!exists) {
                if (confirmedAbsent(uri)) return
                throw BookFileAccessFailure("book_file", "Не удалось проверить файл книги. Обновите папку книг и повторите действие.")
            }
            if (linkedBytes == null) {
                val digest = MessageDigest.getInstance("SHA-256")
                (resolver.openInputStream(uri) ?: error("Файл книги недоступен")).use { input ->
                    val buffer = ByteArray(256 * 1024)
                    while (true) { val n = input.read(buffer); if (n < 0) break; if (n > 0) digest.update(buffer, 0, n) }
                }
                if (digest.digest().joinToString("") { "%02x".format(it) } != expected)
                    throw BookFileAccessFailure("book_file", "Файл изменился. Обновите папку книг перед удалением.")
            }
            if (!checkOnly && !Docs.deleteDocument(resolver, uri) && !confirmedAbsent(uri))
                throw BookFileAccessFailure("book_file", "Хранилище не удалило файл книги")
        } catch (e: BookFileAccessFailure) { throw e }
        catch (e: SecurityException) { throw denied(source) }
        catch (e: Exception) {
            if (confirmedAbsent(uri)) return
            throw BookFileAccessFailure("book_file", "Файл книги временно недоступен. Обновите папку книг и повторите действие. Книга не убрана из библиотеки.")
        }
    }
}
