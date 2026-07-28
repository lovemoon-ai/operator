package com.lovemoon.qrscanner

import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.MultiFormatWriter
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.ResultPoint
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

    private fun terminalLiveFeedQr(): Pair<String, BinaryBitmap> {
        val lines = terminalFixtureLines()
        val payload = lines.first()
        val modules = lines.drop(1)
        val scale = 8
        val width = modules.first().length * scale
        val height = modules.size * scale
        val luma = ByteArray(width * height) { 0xFF.toByte() }
        for ((moduleY, row) in modules.withIndex()) {
            for ((moduleX, value) in row.withIndex()) {
                if (value != '#') continue
                for (dy in 0 until scale) {
                    for (dx in 0 until scale) {
                        luma[(moduleY * scale + dy) * width + moduleX * scale + dx] = 0
                    }
                }
            }
        }
        return payload to BinaryBitmap(
            HybridBinarizer(
                PlanarYUVLuminanceSource(luma, width, height, 0, 0, width, height, false),
            ),
        )
    }

    private fun terminalFixtureLines(): List<String> {
        val resource = requireNotNull(
            javaClass.classLoader?.getResourceAsStream("terminal-live-feed-qr.txt"),
        ) { "terminal QR fixture missing" }
        return resource.bufferedReader().use { it.readLines() }
    }

    private fun squareTerminalLiveFeedQr(): Pair<String, BinaryBitmap> {
        val lines = terminalFixtureLines()
        val payload = lines.first()
        val halfRows = lines.drop(1)
        val cellWidth = 9
        val cellHeight = 19
        val split = cellHeight / 2
        val textRows = (halfRows.size + 1) / 2
        val targetColumns = (textRows * cellHeight.toDouble() / cellWidth).toInt()
        val leftPadding = (targetColumns - halfRows.first().length) / 2
        val width = targetColumns * cellWidth
        val height = textRows * cellHeight
        val luma = ByteArray(width * height) { 0xFF.toByte() }

        for ((halfRow, row) in halfRows.withIndex()) {
            val textRow = halfRow / 2
            val upper = halfRow % 2 == 0
            val y0 = textRow * cellHeight + if (upper) 0 else split
            val halfHeight = if (upper) split else cellHeight - split
            for ((moduleX, value) in row.withIndex()) {
                if (value != '#') continue
                val x0 = (leftPadding + moduleX) * cellWidth
                for (dy in 0 until halfHeight) {
                    for (dx in 0 until cellWidth) {
                        luma[(y0 + dy) * width + x0 + dx] = 0
                    }
                }
            }
        }
        return payload to BinaryBitmap(
            HybridBinarizer(
                PlanarYUVLuminanceSource(luma, width, height, 0, 0, width, height, false),
            ),
        )
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
    fun decodesPythonTerminalLiveFeedQr() {
        // This is not a fresh QR generated by ZXing. The fixture is the
        // black/white half-cell raster emitted by pyoperator's ANSI fallback
        // renderer, so terminals without graphics support remain covered by
        // the headset's real decode path.
        val (payload, bitmap) = terminalLiveFeedQr()
        val result = makeReader().decodeWithState(bitmap)
        assertEquals(payload, result.text)
    }

    @Test
    fun decodesPhysicallySquareTerminalLiveFeedQrWithNineByNineteenCells() {
        val (payload, bitmap) = squareTerminalLiveFeedQr()
        assertTrue(kotlin.math.abs(bitmap.width - bitmap.height) <= 1)
        val result = makeReader().decodeWithState(bitmap)
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

    @Test
    fun mirroredBoundsMapBackToOriginalFrame() {
        val points = arrayOf(
            ResultPoint(100f, 50f),
            ResultPoint(220f, 60f),
            ResultPoint(210f, 190f),
            ResultPoint(95f, 180f),
        )

        val normal = computeQrBounds(points, width = 320, height = 240)
        assertEquals(0.4921875, normal.cx, 0.0001)
        assertEquals(0.5, normal.cy, 0.0001)
        assertEquals(0.390625, normal.w, 0.0001)

        val mirrored = computeQrBounds(points, width = 320, height = 240, mirroredHorizontally = true)
        assertEquals(1.0 - normal.cx, mirrored.cx, 0.0001)
        assertEquals(normal.cy, mirrored.cy, 0.0001)
        assertEquals(normal.w, mirrored.w, 0.0001)
    }
}
