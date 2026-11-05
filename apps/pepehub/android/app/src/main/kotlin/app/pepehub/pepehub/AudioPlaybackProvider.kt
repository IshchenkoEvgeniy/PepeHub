package app.pepehub.pepehub

import android.content.ContentProvider
import android.content.ContentValues
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException

/** A read-only, app-private view of MP3 bytes without trailing APE/ID3 tags. */
class AudioPlaybackProvider : ContentProvider() {
    override fun onCreate() = true
    override fun getType(uri: Uri) = "audio/mpeg"

    override fun openAssetFile(uri: Uri, mode: String): AssetFileDescriptor {
        if (mode != "r") throw FileNotFoundException("Read-only audio source")
        val source = Uri.parse(uri.getQueryParameter("source") ?: throw FileNotFoundException("Missing audio source"))
        val owner = context ?: throw FileNotFoundException("Audio context unavailable")
        if (source.authority == uri.authority || source.scheme !in listOf("file", "content")) {
            throw FileNotFoundException("Unsupported audio source")
        }
        val original = if (source.scheme == "file") {
            val descriptor = ParcelFileDescriptor.open(File(source.path ?: throw FileNotFoundException()), ParcelFileDescriptor.MODE_READ_ONLY)
            AssetFileDescriptor(descriptor, 0, descriptor.statSize)
        } else {
            owner.contentResolver.openAssetFileDescriptor(source, "r") ?: throw FileNotFoundException("Audio source unavailable")
        }
        try {
            val length = if (original.declaredLength >= 0) original.declaredLength
                else original.parcelFileDescriptor.statSize.let { if (it >= 0) it - original.startOffset else -1 }
            if (length < 0) return original // Non-seekable providers keep their original stream.
            val bounded = try {
                ParcelFileDescriptor.AutoCloseInputStream(ParcelFileDescriptor.dup(original.fileDescriptor)).use {
                    Mp3AudioBounds.length(it.channel, original.startOffset, length)
                }
            } catch (_: IOException) { return original }
            return if (bounded == length) original else
                AssetFileDescriptor(original.parcelFileDescriptor, original.startOffset, bounded)
        } catch (failure: Throwable) {
            original.close()
            throw failure
        }
    }

    override fun openFile(uri: Uri, mode: String) = openAssetFile(uri, mode).parcelFileDescriptor
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException("Read-only audio source")
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException("Read-only audio source")
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException("Read-only audio source")
}
