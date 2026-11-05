package app.pepehub.pepehub

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel

/** Excludes recognised trailing tags; never scans or rewrites audio frames. */
internal object Mp3AudioBounds {
    fun length(channel: FileChannel, offset: Long, length: Long): Long {
        require(offset >= 0 && length >= 0)
        fun read(at: Long, count: Int): ByteArray {
            val buffer = ByteBuffer.allocate(count)
            while (buffer.hasRemaining()) {
                if (channel.read(buffer, offset + at + buffer.position()) <= 0) return byteArrayOf()
            }
            return buffer.array()
        }
        fun signature(bytes: ByteArray, text: String) = bytes.size >= text.length &&
            text.indices.all { bytes[it] == text[it].code.toByte() }
        fun uint(bytes: ByteArray, at: Int) = ByteBuffer.wrap(bytes, at, 4)
            .order(ByteOrder.LITTLE_ENDIAN).int.toLong() and 0xffffffffL

        var end = length
        // ID3v1 commonly follows APEv2, including in files from tag editors.
        if (end >= 128 && signature(read(end - 128, 3), "TAG")) end -= 128
        repeat(4) {
            if (end < 32) return end
            val footer = read(end - 32, 32)
            if (!signature(footer, "APETAGEX")) return end
            val version = uint(footer, 8)
            val size = uint(footer, 12)
            val items = uint(footer, 16)
            val flags = uint(footer, 20)
            if (version !in listOf(1000L, 2000L) || size < 32 || size > end ||
                items > (size - 32) / 9 || flags and 0x20000000L != 0L ||
                footer.sliceArray(24..31).any { it != 0.toByte() }) return end
            var start = end - size // APE size includes the footer, not the header.
            if (flags and 0x80000000L != 0L) {
                if (start < 32) return end
                val header = read(start - 32, 32)
                if (!signature(header, "APETAGEX") || uint(header, 8) != version ||
                    uint(header, 12) != size || uint(header, 16) != items ||
                    uint(header, 20) != (flags or 0x20000000L)) return end
                start -= 32
            }
            if (start <= 0) return end
            end = start
        }
        return end
    }
}
