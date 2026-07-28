package com.spatialmp4.livefeed

import java.util.Random
import java.util.zip.Inflater
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DepthTransportCodecTest {
    @Test
    fun compressesAndRoundTripsDepthPlane() {
        val raw = ByteArray(320 * 320 * 2)
        for (index in raw.indices step 2) {
            raw[index] = 0xdc.toByte()
            raw[index + 1] = 0x05
        }

        val encoded = DepthTransportCodec.encode(raw)

        assertTrue(encoded.compressed)
        assertTrue(encoded.payload.size < raw.size)
        assertArrayEquals(raw, inflate(encoded.payload, encoded.uncompressedSize))
    }

    @Test
    fun keepsTinyPayloadRaw() {
        val raw = byteArrayOf(0x01, 0x02, 0x03, 0x04)

        val encoded = DepthTransportCodec.encode(raw)

        assertFalse(encoded.compressed)
        assertTrue(encoded.payload === raw)
    }

    @Test
    fun keepsIncompressibleDepthRaw() {
        val raw = ByteArray(320 * 320 * 2)
        Random(1234L).nextBytes(raw)

        val encoded = DepthTransportCodec.encode(raw)

        assertFalse(encoded.compressed)
        assertTrue(encoded.payload === raw)
    }

    private fun inflate(payload: ByteArray, expectedSize: Int): ByteArray {
        val inflater = Inflater()
        return try {
            inflater.setInput(payload)
            val output = ByteArray(expectedSize)
            val size = inflater.inflate(output)
            assertTrue(inflater.finished())
            output.copyOf(size)
        } finally {
            inflater.end()
        }
    }
}
