package app.pepehub.pepehub

import java.io.ByteArrayInputStream
import java.io.InputStream
import java.security.MessageDigest
import org.junit.Assert.*
import org.junit.Test

class PdfPreviewTest {
    private val bytes = "%PDF-1.4\nunchanged source".toByteArray()
    private val hash get() = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    @Test fun verifiesOriginalSource() {
        PdfPreview.verify(ByteArrayInputStream(bytes), bytes.size.toLong(), hash)
    }
    @Test fun rejectsSameSizeReplacement() {
        val changed = bytes.copyOf().apply { this[lastIndex] = 0 }
        assertThrows(IllegalStateException::class.java) { PdfPreview.verify(ByteArrayInputStream(changed), bytes.size.toLong(), hash) }
    }
    @Test fun rejectsTruncationAndGrowth() {
        assertThrows(IllegalStateException::class.java) { PdfPreview.verify(ByteArrayInputStream(bytes.copyOf(bytes.size - 1)), bytes.size.toLong(), hash) }
        assertThrows(IllegalStateException::class.java) { PdfPreview.verify(ByteArrayInputStream(bytes + byteArrayOf(0)), bytes.size.toLong(), hash) }
    }
    @Test fun rejectsOversizedOrInvalidRequestsBeforeReading() {
        val unreadable = object : InputStream() { override fun read(): Int = error("Must not read") }
        assertThrows(IllegalArgumentException::class.java) { PdfPreview.verify(unreadable, 256L * 1024 * 1024 + 1, hash) }
        assertThrows(IllegalArgumentException::class.java) { PdfPreview.verify(unreadable, bytes.size.toLong(), "wrong") }
    }
}
