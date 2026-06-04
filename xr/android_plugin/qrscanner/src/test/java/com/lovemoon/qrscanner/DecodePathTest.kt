package com.lovemoon.qrscanner

import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.MultiFormatWriter
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.common.BitMatrix
import com.google.zxing.multi.qrcode.QRCodeMultiReader
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-JVM test of the ZXing decode pipeline used by QRScannerPlugin.
 * No Android dependency — runs as part of `./gradlew :qrscanner:test`.
 *
 * Doesn't exercise Camera2 / YUV plane extraction — those need
 * instrumented tests on a real device. What this proves: given a
 * known QR payload, the encoder → binarizer → reader roundtrip
 * recovers the payload byte-for-byte and exposes 4 result points
 * that computeBounds() can use.
 */
class DecodePathTest {

    private fun makeReader(): MultiFormatReader = MultiFormatReader().apply {
        setHints(
            mapOf(
                DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                DecodeHintType.TRY_HARDER to true,
            ),
        )
    }

    private fun encodeQr(payload: String, size: Int = 320): BinaryBitmap {
        val matrix = MultiFormatWriter().encode(payload, BarcodeFormat.QR_CODE, size, size)
        val w = matrix.width
        val h = matrix.height
        // Render to an int[w*h] where black=0x000000, white=0xFFFFFF
        // (RGBLuminanceSource extracts luma from the high byte of each int).
        val pixels = IntArray(w * h)
        for (y in 0 until h) {
            for (x in 0 until w) {
                pixels[y * w + x] = if (matrix[x, y]) 0xFF000000.toInt() else 0xFFFFFFFF.toInt()
            }
        }
        val src = RGBLuminanceSource(w, h, pixels)
        return BinaryBitmap(HybridBinarizer(src))
    }

    private fun encodeQrMatrix(payload: String, size: Int = 180): BitMatrix {
        return MultiFormatWriter().encode(payload, BarcodeFormat.QR_CODE, size, size)
    }

    private fun bitmapWithTwoQrs(leftPayload: String, rightPayload: String): BinaryBitmap {
        val left = encodeQrMatrix(leftPayload)
        val right = encodeQrMatrix(rightPayload)
        val qrSize = left.width
        val margin = 30
        val gap = 40
        val width = margin * 2 + qrSize * 2 + gap
        val height = margin * 2 + qrSize
        val pixels = IntArray(width * height) { 0xFFFFFFFF.toInt() }

        fun blit(matrix: BitMatrix, x0: Int, y0: Int) {
            for (y in 0 until matrix.height) {
                for (x in 0 until matrix.width) {
                    if (matrix[x, y]) {
                        pixels[(y0 + y) * width + (x0 + x)] = 0xFF000000.toInt()
                    }
                }
            }
        }

        blit(left, margin, margin)
        blit(right, margin + qrSize + gap, margin)
        return BinaryBitmap(HybridBinarizer(RGBLuminanceSource(width, height, pixels)))
    }

    @Test
    fun roundtripsTusUrl() {
        val payload = "http://192.168.1.42:3000/api/ingest"
        val reader = makeReader()
        val bitmap = encodeQr(payload)
        val result = reader.decodeWithState(bitmap)
        assertEquals(payload, result.text)
        assertNotNull("ResultPoints required for computeBounds()", result.resultPoints)
        // Standard QR has 3 finder patterns; a 4th alignment pattern
        // appears at version 2+. Either count is acceptable for our
        // bounds computation, which just min/max-es all points.
        val pts = result.resultPoints.size
        assert(pts >= 3) { "expected ≥3 result points, got $pts" }
    }

    @Test
    fun roundtripsLongPayload() {
        // A pessimistic payload — longer than any reasonable ingest URL,
        // forces a higher QR version (more modules, more chance of
        // binarizer pixel-error in real cameras).
        val payload = "https://very-long-host-name.example.org:8443/ingest/v1/sessions?token=abc123xyz&q=a"
        val reader = makeReader()
        val bitmap = encodeQr(payload, size = 480)
        val result = reader.decodeWithState(bitmap)
        assertEquals(payload, result.text)
    }

    @Test
    fun decodesTwoQrsInOneFrame() {
        val left = "http://192.168.1.42:3138/api/ingest/ack?i=left"
        val right = "http://192.168.1.43:3138/api/ingest/ack?i=right"
        val bitmap = bitmapWithTwoQrs(left, right)
        val results = QRCodeMultiReader().decodeMultiple(
            bitmap,
            mapOf(
                DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                DecodeHintType.TRY_HARDER to true,
            ),
        )
        val payloads = results.map { it.text }.toSet()
        assertTrue(payloads.contains(left))
        assertTrue(payloads.contains(right))
    }
}
