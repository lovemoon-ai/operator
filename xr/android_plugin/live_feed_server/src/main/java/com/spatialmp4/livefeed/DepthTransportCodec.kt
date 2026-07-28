package com.spatialmp4.livefeed

import java.util.zip.Deflater

/**
 * Lossless wire compression for canonical little-endian uint16-mm depth frames.
 *
 * Android and Python both ship a zlib implementation, so this keeps the live
 * feed APK dependency-free. Compression is accepted only when it saves enough
 * bytes to cover the protocol/CPU overhead; otherwise callers send the original
 * frame without the compressed flag.
 */
internal object DepthTransportCodec {
    private const val MIN_INPUT_BYTES = 256
    private const val MIN_SAVINGS_BYTES = 32

    data class Encoded(
        val payload: ByteArray,
        val compressed: Boolean,
        val uncompressedSize: Int,
    )

    fun encode(raw: ByteArray): Encoded {
        if (raw.size < MIN_INPUT_BYTES) {
            return Encoded(raw, compressed = false, uncompressedSize = raw.size)
        }

        val deflater = Deflater(Deflater.BEST_SPEED)
        return try {
            deflater.setInput(raw)
            deflater.finish()

            // A compressed frame is only useful when it is smaller than raw,
            // so a raw-sized destination is sufficient. Filling it before the
            // stream finishes means compression lost and we keep the original.
            val output = ByteArray(raw.size)
            var outputSize = 0
            while (!deflater.finished() && outputSize < output.size) {
                val written = deflater.deflate(
                    output,
                    outputSize,
                    output.size - outputSize,
                )
                if (written <= 0) {
                    break
                }
                outputSize += written
            }

            if (
                !deflater.finished()
                || outputSize + MIN_SAVINGS_BYTES >= raw.size
            ) {
                Encoded(raw, compressed = false, uncompressedSize = raw.size)
            } else {
                Encoded(
                    output.copyOf(outputSize),
                    compressed = true,
                    uncompressedSize = raw.size,
                )
            }
        } finally {
            deflater.end()
        }
    }
}
