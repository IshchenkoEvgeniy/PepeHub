package app.pepehub.pepehub

import androidx.media3.common.C
import androidx.media3.common.DataReader
import androidx.media3.extractor.DefaultExtractorInput
import androidx.media3.extractor.DiscardingTrackOutput
import androidx.media3.extractor.Extractor
import androidx.media3.extractor.ExtractorOutput
import androidx.media3.extractor.PositionHolder
import androidx.media3.extractor.SeekMap
import androidx.media3.extractor.mp3.Mp3Extractor
import android.content.pm.ProviderInfo
import android.net.Uri
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class Mp3AudioBoundsTest {
    private data class Result(val durationUs: Long, val failure: Exception?)
    private fun extract(file: File, length: Long): Result {
        var duration = C.TIME_UNSET
        val extractor = Mp3Extractor(Mp3Extractor.FLAG_ENABLE_CONSTANT_BITRATE_SEEKING)
        extractor.init(object : ExtractorOutput {
            override fun track(id: Int, type: Int) = DiscardingTrackOutput()
            override fun endTracks() {}
            override fun seekMap(map: SeekMap) { duration = map.durationUs }
        })
        var failure: Exception? = null
        file.inputStream().use { stream ->
            var remaining = length
            val reader = DataReader { buffer, offset, count ->
                if (remaining == 0L) C.RESULT_END_OF_INPUT else {
                    val n = stream.read(buffer, offset, minOf(count.toLong(), remaining).toInt())
                    if (n > 0) remaining -= n
                    n
                }
            }
            val input = DefaultExtractorInput(reader, 0, length)
            try {
                while (extractor.read(input, PositionHolder()) != Extractor.RESULT_END_OF_INPUT) {}
            } catch (e: Exception) { failure = e }
        }
        extractor.release()
        return Result(duration, failure)
    }
    private fun bounded(file: File) = file.inputStream().use {
        Mp3AudioBounds.length(it.channel, 0, file.length())
    }
    private fun ape(payload: Int): ByteArray {
        fun descriptor(header: Boolean) = ByteBuffer.allocate(32).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("APETAGEX".toByteArray()); putInt(2000); putInt(payload + 32)
            putInt(1); putInt(if (header) 0xa0000000.toInt() else 0x80000000.toInt())
        }.array()
        return descriptor(true) + ByteArray(payload) + descriptor(false)
    }
    private fun mp3() = ByteArray(432 * 1000).apply {
        for (offset in indices step 432) {
            this[offset] = 0xff.toByte(); this[offset + 1] = 0xfb.toByte()
            this[offset + 2] = 0x78; this[offset + 3] = 0x64
        }
    }
    private fun fixture(bytes: ByteArray, action: (File) -> Unit) {
        val file = File.createTempFile("pepe-mp3-bounds-", ".mp3")
        try { file.writeBytes(bytes); action(file) } finally { file.delete() }
    }

    @Test fun largeApeArtworkCausesTheExactSourceErrorAndBoundedInputFixesIt() {
        val audio = mp3()
        val id3v1 = ByteArray(128).apply { "TAG".toByteArray().copyInto(this) }
        fixture(audio + ape(1_686_000) + id3v1) { file ->
            val raw = extract(file, file.length())
            assertTrue(raw.failure?.message.orEmpty().contains("Searched too many bytes"))
            val end = bounded(file)
            assertEquals(audio.size.toLong(), end)
            val clean = extract(file, end)
            assertNull(clean.failure)
            assertEquals(36_000_000L, clean.durationUs)
            assertTrue(raw.durationUs - clean.durationUs > 120_000_000L)
            assertEquals(audio.size + 1_686_000 + 64 + 128L, file.length())
        }
    }

    @Test fun ordinaryMp3AndInvalidApeFooterKeepTheirAudioBytes() {
        val audio = mp3()
        fixture(audio) { assertEquals(it.length(), bounded(it)) }
        val invalid = ape(128).apply { this[size - 32 + 12] = 0x7f; this[size - 32 + 15] = 0x7f }
        fixture(audio + invalid) { assertEquals(it.length(), bounded(it)) }
        val noHeader = ape(128).copyOfRange(32, 128 + 64)
            .apply { this[size - 32 + 23] = 0 }
        fixture(audio + noHeader) { assertEquals(audio.size.toLong(), bounded(it)) }
    }

    @Test fun productionProviderExposesTheBoundedLengthAndPreservesOriginalBytes() {
        val owner = RuntimeEnvironment.getApplication()
        val authority = "${owner.packageName}.audioplayback"
        val provider = AudioPlaybackProvider().apply {
            attachInfo(owner, ProviderInfo().apply {
                this.authority = authority
                applicationInfo = owner.applicationInfo
                exported = false
            })
        }
        val audio = mp3()
        fixture(audio + ape(200_000)) { file ->
            val source = Uri.Builder().scheme("content").authority(authority).path("audio.mp3")
                .appendQueryParameter("source", Uri.fromFile(file).toString()).build()
            provider.openAssetFile(source, "r").use { descriptor ->
                assertEquals(audio.size.toLong(), descriptor.length)
                descriptor.createInputStream().use { input ->
                    assertArrayEquals(audio, input.readBytes())
                }
            }
            assertEquals(audio.size + 200_064L, file.length())
            assertThrows(java.io.FileNotFoundException::class.java) { provider.openAssetFile(source, "w") }
        }
    }

    @Test fun suppliedChapterReproducesTheErrorAndPlaysAllActualFrames() {
        val path = System.getenv("PEPEHUB_MP3_FIXTURE")
        assumeTrue("Optional user-provided MP3 stays outside the repository", !path.isNullOrBlank())
        val file = File(path!!)
        assertEquals(31_326_630L, file.length())
        val raw = extract(file, file.length())
        assertTrue(raw.failure?.message.orEmpty().contains("Searched too many bytes"))
        val end = bounded(file)
        assertEquals(29_640_537L, end)
        val clean = extract(file, end)
        assertNull(clean.failure)
        assertEquals(2_329_380_000L, clean.durationUs)
    }
}
