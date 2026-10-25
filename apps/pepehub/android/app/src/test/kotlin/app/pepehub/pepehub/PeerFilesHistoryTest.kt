package app.pepehub.pepehub

import android.content.Intent
import android.content.ContentResolver
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.CancellationSignal
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract as Docs
import android.provider.DocumentsProvider
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import java.io.File
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Proxy
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implements
import org.robolectric.annotation.Implementation
import org.robolectric.shadows.ShadowContentResolver

/** Robolectric routes the old query overload straight to the provider; Android
 * routes it through the API-26 Bundle query before reaching DocumentsProvider. */
@Implements(ContentResolver::class)
class HistoryContentResolverShadow : ShadowContentResolver() {
    @Implementation(minSdk = 26)
    override fun query(uri: Uri, projection: Array<String>?, selection: String?, selectionArgs: Array<String>?, sortOrder: String?): Cursor? {
        val provider = getProvider(uri)
        if (provider is HistoryDocumentsProvider) return provider.query(uri, projection, Bundle(), null)
        return super.query(uri, projection, selection, selectionArgs, sortOrder)
    }
}

/** A real DocumentsProvider protocol with isolated host files, including move/rename failures. */
class HistoryDocumentsProvider : DocumentsProvider() {
    data class Entry(val id: String, var parent: String?, var name: String, val directory: Boolean, val file: File)
    lateinit var storage: File
    val entries = linkedMapOf<String, Entry>()
    var allowMove = true
    var failPublish = false
    var beforePublish: (() -> Unit)? = null
    var mutateOnRename = false
    var allowDelete = true
    var missingChildThrows = false
    var unavailableChildren = false
    var loadingChildren = false
    var failOpen = false
    override fun onCreate() = true
    fun add(name: String, bytes: ByteArray = byteArrayOf(), parent: String = "root", directory: Boolean = false): Entry {
        val id = UUID.randomUUID().toString()
        val file = File(storage, id)
        if (directory) file.mkdir() else file.writeBytes(bytes)
        return Entry(id, parent, name, directory, file).also { entries[id] = it }
    }
    fun child(parent: String, name: String) = entries.values.singleOrNull { it.parent == parent && it.name == name }
    private fun table(projection: Array<out String>?, selected: List<Entry>): Cursor {
        val columns = projection ?: arrayOf(Docs.Document.COLUMN_DOCUMENT_ID, Docs.Document.COLUMN_DISPLAY_NAME,
            Docs.Document.COLUMN_MIME_TYPE, Docs.Document.COLUMN_SIZE, Docs.Document.COLUMN_LAST_MODIFIED, Docs.Document.COLUMN_FLAGS)
        val cursor = MatrixCursor(columns)
        for (entry in selected) cursor.addRow(columns.map<String, Any?> { when (it) {
            Docs.Document.COLUMN_DOCUMENT_ID -> entry.id
            Docs.Document.COLUMN_DISPLAY_NAME -> entry.name
            Docs.Document.COLUMN_MIME_TYPE -> if (entry.directory) Docs.Document.MIME_TYPE_DIR else "application/octet-stream"
            Docs.Document.COLUMN_SIZE -> if (entry.directory) 0L else entry.file.length()
            Docs.Document.COLUMN_LAST_MODIFIED -> entry.file.lastModified()
            Docs.Document.COLUMN_FLAGS -> Docs.Document.FLAG_SUPPORTS_WRITE or (if (allowDelete) Docs.Document.FLAG_SUPPORTS_DELETE else 0) or
                Docs.Document.FLAG_SUPPORTS_RENAME or Docs.Document.FLAG_SUPPORTS_MOVE or
                (if (entry.directory) Docs.Document.FLAG_DIR_SUPPORTS_CREATE else 0)
            else -> null
        } }.toTypedArray())
        return cursor
    }
    override fun queryRoots(projection: Array<out String>?): Cursor = MatrixCursor(arrayOf(Docs.Root.COLUMN_ROOT_ID))
    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor = table(projection, listOf(entries.getValue(documentId)))
    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor {
        if (unavailableChildren) throw java.io.FileNotFoundException("Storage offline")
        return table(projection, entries.values.filter { it.parent == parentDocumentId }).also {
            if (loadingChildren) (it as MatrixCursor).setExtras(Bundle().apply { putBoolean(Docs.EXTRA_LOADING, true) })
        }
    }
    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean {
        if (missingChildThrows && documentId !in entries)
            throw IllegalArgumentException("Failed to determine if $documentId is child of $parentDocumentId", java.io.FileNotFoundException("Missing file"))
        var current: String? = documentId
        while (current != null) { if (current == parentDocumentId) return true; current = entries[current]?.parent }
        return false
    }
    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        if (failOpen) throw java.io.FileNotFoundException("File temporarily offline")
        return ParcelFileDescriptor.open(entries.getValue(documentId).file, ParcelFileDescriptor.parseMode(mode))
    }
    override fun createDocument(parentDocumentId: String, mimeType: String, displayName: String): String {
        check(child(parentDocumentId, displayName) == null)
        return add(displayName, parent = parentDocumentId, directory = mimeType == Docs.Document.MIME_TYPE_DIR).id
    }
    override fun renameDocument(documentId: String, displayName: String): String {
        val item = entries.getValue(documentId)
        if (mutateOnRename && item.name == "book.epub") item.file.writeBytes(byteArrayOf(9))
        if (item.name.startsWith(".pepehub-transfer-") && displayName == "book.epub") {
            beforePublish?.invoke()
            if (failPublish) throw UnsupportedOperationException("Publish failed")
        }
        check(entries.values.none { it.parent == item.parent && it.id != item.id && it.name == displayName })
        item.name = displayName
        return documentId
    }
    override fun moveDocument(sourceDocumentId: String, sourceParentDocumentId: String, targetParentDocumentId: String): String {
        if (!allowMove) throw UnsupportedOperationException("Move unsupported")
        val item = entries.getValue(sourceDocumentId)
        check(item.parent == sourceParentDocumentId && child(targetParentDocumentId, item.name) == null)
        item.parent = targetParentDocumentId
        return item.id
    }
    override fun deleteDocument(documentId: String) {
        val item = entries.getValue(documentId)
        check(!item.directory) { "Cleanup must never recursively delete directories" }
        check(item.file.delete())
        entries.remove(documentId)
    }
}

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [26, 35], shadows = [HistoryContentResolverShadow::class])
class PeerFilesHistoryTest {
    private val authority = "pepehub.history.test"
    private val tree = Docs.buildTreeDocumentUri(authority, "root")
    private lateinit var provider: HistoryDocumentsProvider
    private lateinit var channel: PeerFilesChannel
    private lateinit var temporary: File
    private val context get() = RuntimeEnvironment.getApplication()
    private val enabled = mapOf("enabled" to true, "maxDays" to 30, "maxBytes" to 500L * 1024 * 1024)
    @Before fun setup() {
        temporary = Files.createTempDirectory("pepehub-saf-history-").toFile()
        provider = HistoryDocumentsProvider().apply {
            storage = temporary
            entries["root"] = HistoryDocumentsProvider.Entry("root", null, "Books", true, temporary)
            attachInfo(this@PeerFilesHistoryTest.context, ProviderInfo().apply {
                this.authority = this@PeerFilesHistoryTest.authority
                exported = true; grantUriPermissions = true
                readPermission = "android.permission.MANAGE_DOCUMENTS"
                writePermission = "android.permission.MANAGE_DOCUMENTS"
                applicationInfo = this@PeerFilesHistoryTest.context.applicationInfo
            })
        }
        ShadowContentResolver.registerProviderInternal(authority, provider)
        context.contentResolver.takePersistableUriPermission(tree,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        val messenger = Proxy.newProxyInstance(BinaryMessenger::class.java.classLoader,
            arrayOf(BinaryMessenger::class.java)) { _, _, _ -> null } as BinaryMessenger
        channel = PeerFilesChannel(context, messenger)
    }
    @After fun close() {
        channel.dispose()
        val actual = temporary.canonicalFile
        val temp = File(requireNotNull(System.getProperty("java.io.tmpdir"))).canonicalFile
        check(actual.toPath().startsWith(temp.toPath()) && actual.name.startsWith("pepehub-saf-history-"))
        check(actual.deleteRecursively())
    }
    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun run(method: String, args: Map<String, Any?> = emptyMap(), policy: Map<String, Any?> = emptyMap()): Any? {
        val execute = PeerFilesChannel::class.java.getDeclaredMethod("execute", MethodCall::class.java).apply { isAccessible = true }
        try { return execute.invoke(channel, MethodCall(method, mapOf("root" to tree.toString(), "history" to policy) + args)) }
        catch (e: InvocationTargetException) { throw e.targetException }
    }
    private fun versions(): String {
        var parent = "root"
        for (name in listOf(".pepehub", "p2p", "versions")) parent = provider.child(parent, name)?.id
            ?: provider.add(name, parent = parent, directory = true).id
        return parent
    }
    private fun name(at: Long = System.currentTimeMillis()) = "v1-$at-${UUID.randomUUID().toString().replace("-", "")}-book.epub"
    private fun prepare(bytes: ByteArray): Map<String, Any?> {
        val hash = digest(bytes)
        val args = mapOf("path" to "book.epub", "stage" to "${digest("book.epub".toByteArray())}-$hash")
        run("stage_prepare", args)
        run("stage_append", args + mapOf("offset" to 0, "bytes" to bytes))
        return args
    }
    @Suppress("UNCHECKED_CAST")
    private fun history(policy: Map<String, Any?> = emptyMap(), migrate: Boolean = false, prune: Boolean = false, clear: Boolean = false) =
        run("history", mapOf("migrate" to migrate, "prune" to prune, "clear" to clear), policy) as Map<String, Any>
    @Test fun metadataPreviewDoesNotOpenOrCreateFiles() {
        provider.add("book.epub", byteArrayOf(1, 2))
        val nested = provider.add("nested", directory = true).id
        provider.add("song.mp3", byteArrayOf(3, 4, 5), parent = nested)
        val ignored = provider.add(".pepehub", directory = true).id
        provider.add("private", byteArrayOf(6), parent = ignored)
        val before = provider.entries.keys.toSet()
        provider.failOpen = true
        val preview = run("preview") as Map<*, *>
        assertEquals(2, preview["files"])
        assertEquals(5L, preview["bytes"])
        assertEquals(setOf("book.epub", "nested/song.mp3"), (preview["examples"] as List<*>).toSet())
        assertEquals(before, provider.entries.keys.toSet())
    }
    @Test fun metadataPreviewRejectsInvalidPortableNamesWithoutWriting() {
        provider.add("../invalid", byteArrayOf(1))
        val before = provider.entries.keys.toSet()
        assertThrows(Exception::class.java) { run("preview") }
        assertEquals(before, provider.entries.keys.toSet())
    }
    @Test fun metadataPreviewFailsWhenProviderIsUnavailableWithoutWriting() {
        provider.unavailableChildren = true
        val before = provider.entries.keys.toSet()
        assertThrows(Exception::class.java) { run("preview") }
        assertEquals(before, provider.entries.keys.toSet())
    }
    @Test fun disabledHistoryReplacesAndDeletesWithoutRetainingMedia() {
        provider.add("book.epub", byteArrayOf(1, 2))
        val stage = prepare(byteArrayOf(3, 4))
        run("stage_publish", stage + ("expected" to digest(byteArrayOf(1, 2))))
        assertArrayEquals(byteArrayOf(3, 4), provider.child("root", "book.epub")!!.file.readBytes())
        assertEquals(1, provider.entries.values.count { !it.directory })
        run("remove", mapOf("path" to "book.epub", "expected" to digest(byteArrayOf(3, 4))))
        assertEquals(0, provider.entries.values.count { !it.directory })
    }
    @Test fun enabledHistoryMovesOldDocumentsToTheServiceDirectory() {
        provider.add("book.epub", byteArrayOf(1)).file.setLastModified(1_000L)
        val stage = prepare(byteArrayOf(2))
        run("stage_publish", stage + ("expected" to digest(byteArrayOf(1))), enabled)
        val previous = provider.entries.values.single { it.parent == versions() }
        assertArrayEquals(byteArrayOf(1), previous.file.readBytes())
        assertTrue(previous.name.startsWith("v1-"))
        assertFalse(provider.entries.values.any { it.parent == "root" && it.name.startsWith(".pepehub-version-") })
        run("remove", mapOf("path" to "book.epub", "expected" to digest(byteArrayOf(2))), enabled)
        assertEquals(2, provider.entries.values.count { it.parent == versions() })
    }
    @Test fun legacyCopiesMigrateWhileDisabledAndAreNotPruned() {
        val at = System.currentTimeMillis() - 90L * 86_400_000
        val nested = provider.add("nested", directory = true).id
        provider.add(".pepehub-version-$at-abcdef12-book.epub", byteArrayOf(1))
        provider.add(".pepehub-version-$at-abcdef34-book.pdf", byteArrayOf(2), parent = nested)
        val report = history(migrate = true, prune = true)
        assertEquals(2, report["moved"])
        assertEquals(2, report["files"])
        assertEquals(0, report["legacy"])
        assertEquals(0, report["removed"])
        assertEquals(2, provider.entries.values.count { it.parent == versions() })
    }
    @Test fun retentionUsesVersionTimeAndRemovesOldestUntilWithinTheByteLimit() {
        val dir = versions(); val now = System.currentTimeMillis()
        val old = provider.add(name(now - 40L * 86_400_000), byteArrayOf(1, 2, 3), dir)
        val middle = provider.add(name(now - 2L * 86_400_000), byteArrayOf(4, 5, 6, 7), dir)
        val recent = provider.add(name(now - 86_400_000), byteArrayOf(8, 9, 10, 11, 12), dir)
        recent.file.setLastModified(1_000L)
        val report = history(enabled + ("maxBytes" to 8L), prune = true)
        assertEquals(2, report["removed"])
        assertEquals(5L, report["bytes"])
        assertFalse(provider.entries.containsKey(old.id)); assertFalse(provider.entries.containsKey(middle.id))
        assertTrue(provider.entries.containsKey(recent.id))
    }
    @Test fun explicitCleanupPreservesCurrentMediaUnknownFilesAndPartialDownloads() {
        val dir = versions()
        provider.add(name(), byteArrayOf(1), dir)
        provider.add(".pepehub-version-${System.currentTimeMillis()}-abcdef12-book.epub", byteArrayOf(2))
        val current = provider.add("book.epub", byteArrayOf(3))
        val unknown = provider.add("my-note.txt", byteArrayOf(4), dir)
        val part = provider.add(".pepehub-transfer-unfinished.part", byteArrayOf(5))
        val report = history(clear = true)
        assertEquals(2, report["removed"]); assertEquals(1, report["unknown"])
        for (entry in listOf(current, unknown, part)) assertTrue(provider.entries.containsKey(entry.id))
    }
    private fun failedPublishRestores(policy: Map<String, Any?>) {
        provider.add("book.epub", byteArrayOf(1))
        val stage = prepare(byteArrayOf(2)); provider.failPublish = true
        assertThrows(Exception::class.java) { run("stage_publish", stage + ("expected" to digest(byteArrayOf(1))), policy) }
        assertArrayEquals(byteArrayOf(1), provider.child("root", "book.epub")!!.file.readBytes())
        assertFalse(provider.entries.values.any { it.name.startsWith(".pepehub-rollback-") || it.name.startsWith("v1-") })
    }
    @Test fun failedPublishRestoresTheBookWithHistoryDisabled() = failedPublishRestores(emptyMap())
    @Test fun failedPublishRestoresTheBookFromTheHistoryDirectory() = failedPublishRestores(enabled)
    @Test fun cleanupDuringFailedPublicationPreservesTheRollbackDocument() {
        provider.add("book.epub", byteArrayOf(1))
        val stage = prepare(byteArrayOf(2)); provider.failPublish = true
        provider.beforePublish = { history(clear = true) }
        assertThrows(Exception::class.java) { run("stage_publish", stage + ("expected" to digest(byteArrayOf(1))), enabled) }
        assertArrayEquals(byteArrayOf(1), provider.child("root", "book.epub")!!.file.readBytes())
    }
    private fun concurrentEditIsPreserved(policy: Map<String, Any?>) {
        provider.add("book.epub", byteArrayOf(1))
        val stage = prepare(byteArrayOf(2)); provider.mutateOnRename = true
        assertThrows(Exception::class.java) { run("stage_publish", stage + ("expected" to digest(byteArrayOf(1))), policy) }
        assertArrayEquals(byteArrayOf(9), provider.child("root", "book.epub")!!.file.readBytes())
    }
    @Test fun concurrentEditSurvivesWithHistoryDisabled() = concurrentEditIsPreserved(emptyMap())
    @Test fun concurrentEditSurvivesWithHistoryEnabled() = concurrentEditIsPreserved(enabled)
    @Test fun unsupportedMovePreservesTheBookAndDisabledHistoryStillWorks() {
        provider.add("book.epub", byteArrayOf(1))
        val stage = prepare(byteArrayOf(2)); provider.allowMove = false
        assertThrows(Exception::class.java) { run("stage_publish", stage + ("expected" to digest(byteArrayOf(1))), enabled) }
        assertArrayEquals(byteArrayOf(1), provider.child("root", "book.epub")!!.file.readBytes())
        run("stage_publish", stage + ("expected" to digest(byteArrayOf(1))))
        assertArrayEquals(byteArrayOf(2), provider.child("root", "book.epub")!!.file.readBytes())
    }
    @Test fun failedLegacyMigrationRetainsTheOnlyCopyUntilExplicitCleanup() {
        val legacy = provider.add(".pepehub-version-${System.currentTimeMillis()}-abcdef12-book.epub", byteArrayOf(1))
        provider.allowMove = false
        val report = history(migrate = true)
        assertEquals(1, report["legacy"])
        assertTrue((report["warnings"] as List<*>).isNotEmpty())
        assertTrue(provider.entries.containsKey(legacy.id))
        assertEquals(1, history(clear = true)["removed"])
    }
    @Test fun aFileInTheHistoryDirectoryPathBlocksArchivingWithoutChangingBooks() {
        val blocker = provider.add(".pepehub", byteArrayOf(9))
        provider.add("book.epub", byteArrayOf(1)); val stage = prepare(byteArrayOf(2))
        assertThrows(Exception::class.java) { run("stage_publish", stage + ("expected" to digest(byteArrayOf(1))), enabled) }
        assertArrayEquals(byteArrayOf(1), provider.child("root", "book.epub")!!.file.readBytes())
        assertArrayEquals(byteArrayOf(9), blocker.file.readBytes())
    }
    @Test fun revokedTreePermissionPreventsHistoryDeletion() {
        val archived = provider.add(name(), byteArrayOf(1), versions())
        context.contentResolver.releasePersistableUriPermission(tree,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        assertThrows(Exception::class.java) { history(clear = true) }
        assertTrue(provider.entries.containsKey(archived.id))
    }
}
