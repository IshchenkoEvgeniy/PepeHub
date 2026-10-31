package app.pepehub.pepehub

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.security.MessageDigest
import kotlin.math.max

/** Seekable SAF previews avoid a second full PDF on local storage. */
object PdfPreview {
    fun verify(input: InputStream, expectedBytes: Long, expectedHash: String) {
        require(expectedBytes in 1..256L * 1024 * 1024 && Regex("^[a-f0-9]{64}$").matches(expectedHash)) { "Некорректные параметры PDF" }
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(256 * 1024)
        var received = 0L
        while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            if (n == 0) continue
            received += n
            check(received <= expectedBytes) { "Размер PDF изменился. Обновите папку книг." }
            digest.update(buffer, 0, n)
        }
        check(received == expectedBytes && digest.digest().joinToString("") { "%02x".format(it) } == expectedHash) {
            "Файл изменился. Обновите папку книг."
        }
    }

    fun render(context: Context, source: Uri, bytes: Long, hash: String): Map<String, Any> {
        require(source.scheme == "content") { "Ожидается content URI" }
        (context.contentResolver.openInputStream(source) ?: error("PDF недоступен")).use { verify(it, bytes, hash) }
        val descriptor = context.contentResolver.openFileDescriptor(source, "r") ?: error("PDF недоступен")
        descriptor.use {
            PdfRenderer(it).use { renderer ->
                check(renderer.pageCount in 1..20000) { "Недопустимое число страниц PDF" }
                renderer.openPage(0).use { page ->
                    val longest = max(page.width, page.height)
                    check(longest > 0) { "Некорректный размер страницы PDF" }
                    val bitmap = Bitmap.createBitmap(max(1, page.width * 600 / longest), max(1, page.height * 600 / longest), Bitmap.Config.ARGB_8888)
                    try {
                        bitmap.eraseColor(Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        val output = ByteArrayOutputStream()
                        check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) { "Обложка PDF не сохранена" }
                        return mapOf("png" to output.toByteArray(), "pages" to renderer.pageCount)
                    } finally { bitmap.recycle() }
                }
            }
        }
    }
}
