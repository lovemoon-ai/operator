package com.spatialmp4.capturecommon

/**
 * Converts the D16_UNORM image returned by XR_META_environment_depth into the
 * canonical little-endian uint16 millimetre payload used by SpatialMP4.
 *
 * The implementation is shared by every Android capture provider so the
 * recorded depth has identical units and invalid-value handling regardless of
 * which OpenXR runtime supplied the frame.
 */
object OpenXrDepthConverter {
    fun rhToU16Mm(
        raw: ByteArray,
        width: Int,
        height: Int,
        inverseProjectionViewRow3: DoubleArray,
    ): ByteArray {
        if (width <= 0 || height <= 0) return ByteArray(0)
        val expected = width * height * 2
        if (raw.size < expected) return ByteArray(0)
        if (inverseProjectionViewRow3.size < 4) return ByteArray(0)

        val out = ByteArray(expected)
        val r0 = inverseProjectionViewRow3[0]
        val r1 = inverseProjectionViewRow3[1]
        val r2 = inverseProjectionViewRow3[2]
        val r3 = inverseProjectionViewRow3[3]
        val invW = 1.0 / width.toDouble()
        val invH = 1.0 / height.toDouble()
        val invMax = 1.0 / 65535.0
        var index = 0
        for (y in 0 until height) {
            val clipY = 2.0 * (y.toDouble() + 0.5) * invH - 1.0
            val r1y = r1 * clipY
            for (x in 0 until width) {
                val srcOffset = index shl 1
                val raw0 = raw[srcOffset].toInt() and 0xff
                val raw1 = raw[srcOffset + 1].toInt() and 0xff
                val normalized = (raw0 or (raw1 shl 8)) * invMax
                var millimetres = 0
                if (normalized in 0.0..1.0) {
                    val clipX = 2.0 * (x.toDouble() + 0.5) * invW - 1.0
                    val clipZ = 2.0 * normalized - 1.0
                    val homogeneousW = r0 * clipX + r1y + r2 * clipZ + r3
                    if (homogeneousW > 0.0) {
                        val metres = 1.0 / homogeneousW
                        if (metres.isFinite() && metres > 0.0) {
                            millimetres = (metres * 1000.0 + 0.5)
                                .toInt()
                                .coerceIn(0, 65535)
                        }
                    }
                }
                out[srcOffset] = (millimetres and 0xff).toByte()
                out[srcOffset + 1] = ((millimetres shr 8) and 0xff).toByte()
                index += 1
            }
        }
        return out
    }
}
