package com.spatialmp4.capturecommon

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class OpenXrDepthConverterTest {
    @Test
    fun convertsToCanonicalLittleEndianMillimetres() {
        val raw = byteArrayOf(0x00, 0x00, 0xff.toByte(), 0xff.toByte())

        val converted = OpenXrDepthConverter.rhToU16Mm(
            raw,
            width = 2,
            height = 1,
            inverseProjectionViewRow3 = doubleArrayOf(0.0, 0.0, 0.0, 1.0),
        )

        assertArrayEquals(byteArrayOf(0xe8.toByte(), 0x03, 0xe8.toByte(), 0x03), converted)
    }

    @Test
    fun clampsDistancesThatExceedUint16Millimetres() {
        val converted = OpenXrDepthConverter.rhToU16Mm(
            byteArrayOf(0x00, 0x00),
            width = 1,
            height = 1,
            inverseProjectionViewRow3 = doubleArrayOf(0.0, 0.0, 0.0, 0.01),
        )

        assertArrayEquals(byteArrayOf(0xff.toByte(), 0xff.toByte()), converted)
    }

    @Test
    fun rejectsIncompleteInput() {
        assertEquals(
            0,
            OpenXrDepthConverter.rhToU16Mm(
                byteArrayOf(0x00),
                width = 1,
                height = 1,
                inverseProjectionViewRow3 = doubleArrayOf(0.0, 0.0, 0.0, 1.0),
            ).size,
        )
    }
}
