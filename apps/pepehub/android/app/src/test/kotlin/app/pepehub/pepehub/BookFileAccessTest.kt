package app.pepehub.pepehub

import android.app.Activity
import android.content.Intent
import android.content.pm.ProviderInfo
import android.net.Uri
import android.os.Looper
import android.provider.DocumentsContract as Docs
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.reflect.Proxy
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [26, 28, 35], shadows = [HistoryContentResolverShadow::class])
class BookFileAccessTest {
    private val authority = "pepehub.book.access.test"
    private val tree = Docs.buildTreeDocumentUri(authority, "root")
    private val modes = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    private val context get() = RuntimeEnvironment.getApplication()
    private lateinit var temporary: File
    private lateinit var provider: HistoryDocumentsProvider
    private lateinit var access: BookFileAccess
    private var channel: AudioFolderChannel? = null
    private val original = byteArrayOf(1, 2, 3)
    private val hash get() = MessageDigest.getInstance("SHA-256").digest(original).joinToString("") { "%02x".format(it) }
    @Before fun setup() {
        temporary = Files.createTempDirectory("pepehub-book-access-").toFile()
        provider = HistoryDocumentsProvider().apply {
            storage = temporary
            entries["root"] = HistoryDocumentsProvider.Entry("root", null, "Books", true, temporary)
            attachInfo(this@BookFileAccessTest.context, ProviderInfo().apply {
                this.authority = this@BookFileAccessTest.authority
                exported = true; grantUriPermissions = true
                readPermission = "android.permission.MANAGE_DOCUMENTS"; writePermission = readPermission
                applicationInfo = this@BookFileAccessTest.context.applicationInfo
            })
        }
        ShadowContentResolver.registerProviderInternal(authority, provider)
        access = BookFileAccess(context)
    }
    @After fun close() {
        channel?.dispose()
        val actual = temporary.canonicalFile
        val temp = File(requireNotNull(System.getProperty("java.io.tmpdir"))).canonicalFile
        check(actual.toPath().startsWith(temp.toPath()) && actual.name.startsWith("pepehub-book-access-"))
        check(actual.deleteRecursively())
    }
    private fun grant(uri: Uri = tree, flags: Int = modes) = context.contentResolver.takePersistableUriPermission(uri, flags)
    private fun book(parent: String = "root") = provider.add("book.epub", original, parent)
    private fun uri(id: String, root: Uri = tree) = Docs.buildDocumentUriUsingTree(root, id)
    @Test fun legacyReadOnlyGrantReportsTheExactFolderAndPreservesTheBook() {
        val book = book(); grant(flags = Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val error = assertThrows(BookFileAccessFailure::class.java) { access.delete(uri(book.id).toString(), hash, true) }
        assertEquals("book_write_permission", error.code); assertEquals(tree, error.root)
        assertArrayEquals(original, book.file.readBytes())
    }
    @Test fun restoredWriteGrantAllowsPreflightThenDeletionWithoutCopyingTheBook() {
        val book = book(); grant(flags = Intent.FLAG_GRANT_READ_URI_PERMISSION)
        assertTrue(access.grant(tree, tree, modes))
        access.delete(uri(book.id).toString(), hash, true)
        assertArrayEquals(original, book.file.readBytes())
        access.delete(uri(book.id).toString(), hash, false)
        assertFalse(book.file.exists())
    }
    @Test fun aDirectDocumentGrantAlsoAllowsDeletion() {
        val book = book(); val document = Docs.buildDocumentUri(authority, book.id)
        grant(document)
        access.delete(document.toString(), hash, false)
        assertFalse(book.file.exists())
    }
    @Test fun aNewAncestorGrantRebindsAnOldReadOnlyTreeUri() {
        val folder = provider.add("Subfolder", directory = true)
        val book = book(folder.id)
        val subtree = Docs.buildTreeDocumentUri(authority, folder.id)
        grant(subtree, Intent.FLAG_GRANT_READ_URI_PERMISSION); grant()
        access.delete(uri(book.id, subtree).toString(), hash, false)
        assertFalse(book.file.exists())
    }
    @Test fun anUnrelatedGrantNeverAuthorizesDeletion() {
        val folder = provider.add("Other", directory = true)
        val book = book(); grant(Docs.buildTreeDocumentUri(authority, folder.id))
        assertThrows(BookFileAccessFailure::class.java) { access.delete(uri(book.id).toString(), hash, false) }
        assertArrayEquals(original, book.file.readBytes())
    }
    @Test fun aForgedTreeBindingIsRejectedByTheProvider() {
        val book = book(); provider.entries[book.id]!!.parent = null
        grant()
        assertThrows(BookFileAccessFailure::class.java) { access.delete(uri(book.id).toString(), hash, false) }
        assertArrayEquals(original, book.file.readBytes())
    }
    @Test fun neitherTheRootNorANestedDirectoryCanBeDeleted() {
        grant(); val folder = provider.add("Folder", directory = true)
        assertThrows(BookFileAccessFailure::class.java) { access.delete(uri("root").toString(), hash, false) }
        assertThrows(BookFileAccessFailure::class.java) { access.delete(uri(folder.id).toString(), hash, false) }
        assertTrue(provider.entries.containsKey(folder.id)); assertTrue(temporary.exists())
    }
    @Test fun editingTheBookWhileThePickerIsOpenPreventsDeletion() {
        val book = book(); grant(flags = Intent.FLAG_GRANT_READ_URI_PERMISSION)
        book.file.writeBytes(byteArrayOf(9)); access.grant(tree, tree, modes)
        assertThrows(BookFileAccessFailure::class.java) { access.delete(uri(book.id).toString(), hash, false) }
        assertArrayEquals(byteArrayOf(9), book.file.readBytes())
    }
    private fun missingBook(): Uri {
        val book = book(); val document = uri(book.id)
        provider.deleteDocument(book.id); provider.missingChildThrows = true
        return document
    }
    @Test fun anAlreadyDeletedDocumentIsConfirmedAbsentDespiteWrappedFileNotFound() {
        grant(); val document = missingBook()
        access.delete(document.toString(), hash, true)
        access.delete(document.toString(), hash, false)
        assertEquals(1, provider.entries.size)
    }
    @Test fun aFileDeletedBetweenPreflightAndCommitIsAlreadyGone() {
        grant(); val book = book(); val document = uri(book.id)
        access.delete(document.toString(), hash, true)
        provider.deleteDocument(book.id); provider.missingChildThrows = true
        access.delete(document.toString(), hash, false)
    }
    @Test fun anAbsentFileNeedsNoWritePermissionWhenItsTreeRemainsReadable() {
        grant(flags = Intent.FLAG_GRANT_READ_URI_PERMISSION); val document = missingBook()
        access.delete(document.toString(), hash, false)
        assertFalse(context.contentResolver.persistedUriPermissions.single().isWritePermission)
    }
    @Test fun anUnavailableTreeIsNeverMistakenForAnAlreadyDeletedBook() {
        grant(); val document = missingBook(); provider.unavailableChildren = true
        val error = assertThrows(BookFileAccessFailure::class.java) { access.delete(document.toString(), hash, false) }
        assertEquals("book_file", error.code)
    }
    @Test fun aPartialProviderListingCannotConfirmAbsence() {
        grant(); val document = missingBook(); provider.loadingChildren = true
        val error = assertThrows(BookFileAccessFailure::class.java) { access.delete(document.toString(), hash, false) }
        assertEquals("book_file", error.code)
    }
    @Test fun aTemporarilyUnreadableFileRemainsPresentAndIsNotDeleted() {
        grant(); val book = book(); provider.failOpen = true
        val error = assertThrows(BookFileAccessFailure::class.java) { access.delete(uri(book.id).toString(), hash, false) }
        assertEquals("book_file", error.code)
        assertArrayEquals(original, book.file.readBytes())
    }
    @Test fun aProviderWithoutDeleteSupportReportsAnActionableFailure() {
        val book = book(); grant(); provider.allowDelete = false
        val error = assertThrows(BookFileAccessFailure::class.java) { access.delete(uri(book.id).toString(), hash, false) }
        assertEquals("book_file", error.code); assertTrue(error.message!!.contains("файловый менеджер"))
        assertArrayEquals(original, book.file.readBytes())
    }
    @Test fun aDifferentSelectionNeverChangesTheOldGrantOrDeletesFiles() {
        val book = book(); grant(flags = Intent.FLAG_GRANT_READ_URI_PERMISSION)
        assertThrows(BookFileAccessFailure::class.java) { access.grant(tree, Docs.buildTreeDocumentUri(authority, "other"), modes) }
        assertFalse(context.contentResolver.persistedUriPermissions.single().isWritePermission)
        assertArrayEquals(original, book.file.readBytes())
    }
    @Test fun aReadOnlySelectionDoesNotPretendToRestoreWriteAccess() {
        grant(flags = Intent.FLAG_GRANT_READ_URI_PERMISSION)
        assertThrows(BookFileAccessFailure::class.java) { access.grant(tree, tree, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        assertFalse(context.contentResolver.persistedUriPermissions.single().isWritePermission)
        assertFalse(access.grant(tree, null, 0))
    }
    private class Reply : MethodChannel.Result {
        var calls = 0; var value: Any? = null; var error: String? = null
        override fun success(result: Any?) { calls++; value = result }
        override fun error(code: String, message: String?, details: Any?) { calls++; error = code }
        override fun notImplemented() { calls++; error = "notImplemented" }
    }
    private fun bridge(): Pair<Activity, AudioFolderChannel> {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val messenger = Proxy.newProxyInstance(BinaryMessenger::class.java.classLoader, arrayOf(BinaryMessenger::class.java)) { _, _, _ -> null } as BinaryMessenger
        return activity to AudioFolderChannel(activity, messenger).also { channel = it }
    }
    private fun awaitBridge() {
        val worker = AudioFolderChannel::class.java.getDeclaredField("worker").apply { isAccessible = true }.get(channel) as ExecutorService
        worker.submit {}.get(10, TimeUnit.SECONDS)
        shadowOf(Looper.getMainLooper()).idle()
    }
    @Test fun theSystemPickerStartsInTheExactFolderAndCancellationStopsTheOperation() {
        val (activity, bridge) = bridge(); val book = book(); val reply = Reply()
        bridge.requestBookWriteAccess(tree.toString(), reply)
        val launched = shadowOf(activity).nextStartedActivityForResult
        assertEquals(Intent.ACTION_OPEN_DOCUMENT_TREE, launched.intent.action)
        assertEquals(4714, launched.requestCode)
        assertEquals(uri("root"), launched.intent.getParcelableExtra<Uri>(Docs.EXTRA_INITIAL_URI))
        assertEquals(modes, launched.intent.flags and modes)
        val second = Reply(); bridge.requestBookWriteAccess(tree.toString(), second); assertEquals("busy", second.error)
        assertTrue(bridge.onActivityResult(4714, Activity.RESULT_CANCELED, null))
        assertEquals(false, reply.value); assertEquals(1, reply.calls)
        assertArrayEquals(original, book.file.readBytes())
    }
    @Test fun theSystemResultOnlyRestoresAccessAndNeverDeletesOrImportsFiles() {
        val (_, bridge) = bridge(); val book = book(); val reply = Reply()
        bridge.requestBookWriteAccess(tree.toString(), reply)
        bridge.onActivityResult(4714, Activity.RESULT_OK, Intent().setData(tree).addFlags(modes))
        awaitBridge(); assertEquals(true, reply.value); assertNull(reply.error)
        assertArrayEquals(original, book.file.readBytes()); assertEquals(2, provider.entries.size)
        bridge.onActivityResult(4714, Activity.RESULT_OK, Intent().setData(tree).addFlags(modes))
        assertEquals(1, reply.calls)
    }
    private fun scanFolder(bridge: AudioFolderChannel): Reply {
        val result = Reply()
        AudioFolderChannel::class.java.getDeclaredField("pending").apply { isAccessible = true }.set(bridge, result)
        AudioFolderChannel::class.java.getDeclaredField("pendingBooks").apply { isAccessible = true }.set(bridge, true)
        bridge.onActivityResult(4712, Activity.RESULT_OK, Intent().setData(tree).addFlags(modes))
        awaitBridge()
        return result
    }
    @Test fun aLoadingFolderScanNeverPublishesAnEmptyLibrarySnapshot() {
        val (_, bridge) = bridge(); grant(); val book = book(); provider.loadingChildren = true
        val result = scanFolder(bridge)
        assertEquals("folder_unavailable", result.error); assertNull(result.value)
        assertArrayEquals(original, book.file.readBytes())
    }
    @Test fun aMissingFolderRootNeverPublishesAnEmptyLibrarySnapshot() {
        val (_, bridge) = bridge(); grant(); val book = book(); provider.entries.remove("root")
        val result = scanFolder(bridge)
        assertEquals("folder_unavailable", result.error); assertNull(result.value)
        assertArrayEquals(original, book.file.readBytes())
    }
    @Test fun aReadableEmptyFolderCanPublishACompleteSnapshot() {
        val (_, bridge) = bridge(); grant()
        val result = scanFolder(bridge)
        assertNull(result.error); assertEquals(emptyList<Any>(), (result.value as Map<*, *>)["files"])
    }
}
