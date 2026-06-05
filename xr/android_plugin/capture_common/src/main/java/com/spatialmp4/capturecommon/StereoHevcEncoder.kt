package com.spatialmp4.capturecommon

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.util.Log
import com.spatialmp4.contract.Intrinsics
import com.spatialmp4.contract.RgbStreamConfig
import com.spatialmp4.contract.SpatialDataSink
import java.nio.ByteBuffer
import kotlin.math.abs
import kotlin.math.max

data class YuvPlaneCapture(
    val index: Int,
    val rowStride: Int,
    val pixelStride: Int,
    val bytes: ByteArray
)

enum class ChromaLayout {
    UNKNOWN,
    NV12,
    NV21
}

data class CapturedYuvFrame(
    val eye: String,
    val timestampNs: Long,
    val width: Int,
    val height: Int,
    val planes: List<YuvPlaneCapture>,
    val chromaLayout: ChromaLayout = ChromaLayout.UNKNOWN
)

class StereoHevcEncoder(
    private val dataSink: SpatialDataSink,
    private val eyeWidth: Int,
    private val eyeHeight: Int,
    private val fps: Int,
    private val bitrate: Int,
    private val stereo: Boolean,
    // Per-camera Intrinsics in stereo SBS order (left, right). Passed once at
    // construction so the encoder can hand them to the sink as part of
    // RgbStreamConfig when MediaCodec emits codec-specific data.
    private val cameraIntrinsics: List<Intrinsics>,
    private val onError: (String) -> Unit,
    // Lightweight counters surfaced by provider popMetricsJson hooks so
    // the 1Hz GDScript ticker can spot stereo-pair / encoder-output backlogs.
    private val onPairEncoded: () -> Unit = {},
    private val onMonoEncoded: () -> Unit = {},
    private val onPacketEmitted: () -> Unit = {}
) {
    private val frameDurationUs = 1_000_000L / max(fps, 1)
    private val encodedWidth = if (stereo) eyeWidth * 2 else eyeWidth
    private val encodedHeight = eyeHeight
    private val bufferInfo = MediaCodec.BufferInfo()
    private var codec: MediaCodec? = null
    private var pendingLeft: CapturedYuvFrame? = null
    private var pendingRight: CapturedYuvFrame? = null
    private var colorFormat = MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
    private var stopped = false

    fun start(): Boolean {
        return try {
            val codecInfo = chooseHevcEncoder()
            colorFormat = chooseColorFormat(codecInfo)
            val format = MediaFormat.createVideoFormat(
                MediaFormat.MIMETYPE_VIDEO_HEVC,
                encodedWidth,
                encodedHeight
            )
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, colorFormat)
            format.setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
            format.setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
            format.setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
            format.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            format.setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            format.setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)

            codec = MediaCodec.createByCodecName(codecInfo.name).apply {
                configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                start()
            }
            Log.i(TAG, "started HEVC encoder ${codecInfo.name} ${encodedWidth}x$encodedHeight stereo=$stereo fps=$fps bitrate=$bitrate color=$colorFormat colorspace=bt709/sdr/limited")
            true
        } catch (error: Exception) {
            onError("Failed to start HEVC encoder: ${error.message}")
            false
        }
    }

    fun offer(frame: CapturedYuvFrame) {
        if (stopped) {
            return
        }
        if (frame.width != eyeWidth || frame.height != eyeHeight) {
            onError("Dropping RGB frame with unexpected size ${frame.width}x${frame.height}")
            return
        }

        if (!stereo) {
            if (frame.eye == "left") {
                encodePayload(buildMonoPayload(frame), frame.timestampNs, "left RGB frame")
                onMonoEncoded()
            }
            return
        }
        if (frame.eye == "left") {
            pendingLeft = frame
        } else {
            pendingRight = frame
        }
        encodeAvailablePair()
    }

    fun stopAndDrain() {
        if (stopped) {
            return
        }
        stopped = true
        val localCodec = codec ?: return
        try {
            drainEncoder(false)
            val inputIndex = localCodec.dequeueInputBuffer(20_000)
            if (inputIndex >= 0) {
                localCodec.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            }
            drainEncoder(true)
        } catch (error: Exception) {
            onError("Failed to drain HEVC encoder: ${error.message}")
        } finally {
            try {
                localCodec.stop()
            } catch (_: Exception) {
            }
            localCodec.release()
            codec = null
        }
    }

    private fun encodeAvailablePair() {
        while (pendingLeft != null && pendingRight != null) {
            val left = pendingLeft ?: return
            val right = pendingRight ?: return
            val delta = abs(left.timestampNs - right.timestampNs)
            if (delta > MAX_PAIR_DELTA_NS) {
                if (left.timestampNs < right.timestampNs) {
                    pendingLeft = null
                } else {
                    pendingRight = null
                }
                continue
            }

            pendingLeft = null
            pendingRight = null
            encodePair(left, right, minOf(left.timestampNs, right.timestampNs))
        }
    }

    private fun encodePair(left: CapturedYuvFrame, right: CapturedYuvFrame, timestampNs: Long) {
        encodePayload(buildStereoPayload(left, right), timestampNs, "RGB pair")
        onPairEncoded()
    }

    private fun encodePayload(payload: ByteArray, timestampNs: Long, label: String) {
        val localCodec = codec ?: return
        drainEncoder(false)
        val inputIndex = localCodec.dequeueInputBuffer(10_000)
        if (inputIndex < 0) {
            onError("HEVC encoder input buffer was not available; dropping $label")
            return
        }
        val inputBuffer = localCodec.getInputBuffer(inputIndex) ?: run {
            onError("HEVC encoder returned null input buffer")
            return
        }
        inputBuffer.clear()
        if (payload.size > inputBuffer.remaining()) {
            onError("HEVC input buffer too small: ${inputBuffer.remaining()} < ${payload.size}")
            localCodec.queueInputBuffer(inputIndex, 0, 0, timestampNs / 1000L, 0)
            return
        }
        inputBuffer.put(payload)
        localCodec.queueInputBuffer(inputIndex, 0, payload.size, timestampNs / 1000L, 0)
    }

    private fun drainEncoder(endOfStream: Boolean) {
        val localCodec = codec ?: return
        while (true) {
            when (val outputIndex = localCodec.dequeueOutputBuffer(bufferInfo, if (endOfStream) 20_000 else 0)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> {
                    if (!endOfStream) {
                        return
                    }
                }
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    configureNativeHevc(localCodec.outputFormat)
                }
                MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> {
                    continue
                }
                else -> {
                    if (outputIndex < 0) {
                        continue
                    }
                    val outputBuffer = localCodec.getOutputBuffer(outputIndex)
                    if (outputBuffer != null && bufferInfo.size > 0) {
                        if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                            // Forward the MediaCodec output buffer as-is to the
                            // sink: the SpatialDataSink contract documents
                            // data.remaining() as the packet bytes, valid only
                            // until onRgbPacket returns. The current muxer
                            // implementation copies through a ByteArray before
                            // queueing for the I/O thread (a future direct-buffer
                            // JNI variant can skip that copy without touching
                            // this call site).
                            outputBuffer.position(bufferInfo.offset)
                            outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                            val isKey = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0
                            dataSink.onRgbPacket(
                                outputBuffer,
                                bufferInfo.presentationTimeUs * 1_000L,
                                frameDurationUs * 1_000L,
                                isKey
                            )
                            onPacketEmitted()
                        }
                    }
                    localCodec.releaseOutputBuffer(outputIndex, false)
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        return
                    }
                }
            }
        }
    }

    private fun configureNativeHevc(format: MediaFormat) {
        val csd = collectCodecConfig(format)
        if (csd.isEmpty()) {
            onError("HEVC encoder output format did not include codec config")
            return
        }
        // Hand the codec config through the SpatialDataSink contract. The
        // muxer is responsible for ICAM/ECAM/DSTR boxes -- it consumes the
        // per-camera intrinsics list we captured at construction time.
        val config = RgbStreamConfig(
            width = encodedWidth,
            height = encodedHeight,
            fps = fps,
            cameras = cameraIntrinsics,
            csd = csd
        )
        dataSink.onRgbCsd(config)
    }

    private fun collectCodecConfig(format: MediaFormat): ByteArray {
        val chunks = mutableListOf<ByteArray>()
        for (key in listOf("csd-0", "csd-1", "csd-2")) {
            val buffer = try {
                format.getByteBuffer(key)
            } catch (_: Exception) {
                null
            }
            if (buffer != null) {
                chunks += buffer.toByteArray()
            }
        }
        val size = chunks.sumOf { it.size }
        val out = ByteArray(size)
        var offset = 0
        for (chunk in chunks) {
            System.arraycopy(chunk, 0, out, offset, chunk.size)
            offset += chunk.size
        }
        return out
    }

    private fun buildStereoPayload(left: CapturedYuvFrame, right: CapturedYuvFrame): ByteArray {
        return if (colorFormat == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar) {
            buildStereoNv12(left, right)
        } else {
            buildStereoI420(left, right)
        }
    }

    private fun buildMonoPayload(frame: CapturedYuvFrame): ByteArray {
        return if (colorFormat == MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar) {
            buildMonoNv12(frame)
        } else {
            buildMonoI420(frame)
        }
    }

    private fun buildStereoI420(left: CapturedYuvFrame, right: CapturedYuvFrame): ByteArray {
        val ySize = encodedWidth * encodedHeight
        val uvStride = encodedWidth / 2
        val uvHeight = encodedHeight / 2
        val uvSize = uvStride * uvHeight
        val out = ByteArray(ySize + uvSize * 2)
        copyEyePlane(left, 0, eyeWidth, eyeHeight, out, 0, encodedWidth, 0)
        copyEyePlane(right, 0, eyeWidth, eyeHeight, out, 0, encodedWidth, eyeWidth)
        copyEyePlane(left, 1, eyeWidth / 2, eyeHeight / 2, out, ySize, uvStride, 0)
        copyEyePlane(right, 1, eyeWidth / 2, eyeHeight / 2, out, ySize, uvStride, eyeWidth / 2)
        copyEyePlane(left, 2, eyeWidth / 2, eyeHeight / 2, out, ySize + uvSize, uvStride, 0)
        copyEyePlane(right, 2, eyeWidth / 2, eyeHeight / 2, out, ySize + uvSize, uvStride, eyeWidth / 2)
        return out
    }

    private fun buildStereoNv12(left: CapturedYuvFrame, right: CapturedYuvFrame): ByteArray {
        val ySize = encodedWidth * encodedHeight
        val uvStride = encodedWidth
        val uvHeight = encodedHeight / 2
        val out = ByteArray(ySize + uvStride * uvHeight)
        copyEyePlane(left, 0, eyeWidth, eyeHeight, out, 0, encodedWidth, 0)
        copyEyePlane(right, 0, eyeWidth, eyeHeight, out, 0, encodedWidth, eyeWidth)
        interleaveEyeUv(left, out, ySize, uvStride, 0)
        interleaveEyeUv(right, out, ySize, uvStride, eyeWidth)
        return out
    }

    private fun buildMonoI420(frame: CapturedYuvFrame): ByteArray {
        val ySize = eyeWidth * eyeHeight
        val uvStride = eyeWidth / 2
        val uvHeight = eyeHeight / 2
        val uvSize = uvStride * uvHeight
        val out = ByteArray(ySize + uvSize * 2)
        copyEyePlane(frame, 0, eyeWidth, eyeHeight, out, 0, eyeWidth, 0)
        copyEyePlane(frame, 1, eyeWidth / 2, eyeHeight / 2, out, ySize, uvStride, 0)
        copyEyePlane(frame, 2, eyeWidth / 2, eyeHeight / 2, out, ySize + uvSize, uvStride, 0)
        return out
    }

    private fun buildMonoNv12(frame: CapturedYuvFrame): ByteArray {
        val ySize = eyeWidth * eyeHeight
        val out = ByteArray(ySize + eyeWidth * eyeHeight / 2)
        copyEyePlane(frame, 0, eyeWidth, eyeHeight, out, 0, eyeWidth, 0)
        interleaveEyeUv(frame, out, ySize, eyeWidth, 0)
        return out
    }

    // Copy one eye's single plane into the SBS payload. When the camera plane
    // is contiguous (pixelStride == 1) — which is always true for Y per the
    // YUV_420_888 spec, and also common for U/V when the camera reports a
    // planar layout — we can move each row with a single native arraycopy,
    // which is ~100x faster than the Kotlin byte-by-byte loop and is the
    // bulk of the speed-up that prevents stereo recording from saturating a
    // CPU core.
    private fun copyEyePlane(
        frame: CapturedYuvFrame,
        planeIndex: Int,
        planeWidth: Int,
        planeHeight: Int,
        dst: ByteArray,
        dstOffset: Int,
        dstStride: Int,
        dstX: Int
    ) {
        val plane = frame.planes.firstOrNull { it.index == planeIndex } ?: return
        val src = plane.bytes
        val srcRowStride = plane.rowStride
        val srcPixelStride = plane.pixelStride
        val srcSize = src.size
        if (srcPixelStride == 1) {
            for (y in 0 until planeHeight) {
                val srcRow = y * srcRowStride
                val dstRow = dstOffset + y * dstStride + dstX
                val rowBytes = minOf(planeWidth, srcSize - srcRow, dst.size - dstRow)
                if (rowBytes <= 0) continue
                System.arraycopy(src, srcRow, dst, dstRow, rowBytes)
            }
            return
        }
        // Subsampled / interleaved layout (e.g. U or V plane viewed as a
        // standalone plane in NV12/NV21). Fall back to a tight per-byte loop
        // with hoisted bounds so the JIT does not re-check them.
        for (y in 0 until planeHeight) {
            val srcRow = y * srcRowStride
            val dstRow = dstOffset + y * dstStride + dstX
            val rowLimit = minOf(planeWidth, (srcSize - srcRow + srcPixelStride - 1) / srcPixelStride)
            var srcIdx = srcRow
            var dstIdx = dstRow
            var x = 0
            while (x < rowLimit) {
                dst[dstIdx] = src[srcIdx]
                srcIdx += srcPixelStride
                dstIdx += 1
                x += 1
            }
        }
    }

    // Interleave the U / V planes into the NV12 chroma row layout the encoder
    // expects. Only use the semi-planar row fast path when the backing layout
    // was positively identified; otherwise use the YUV_420_888 plane contract
    // and pull U/V samples from their own planes to avoid color swaps.
    private fun interleaveEyeUv(frame: CapturedYuvFrame, dst: ByteArray, dstOffset: Int, dstStride: Int, dstX: Int) {
        val u = frame.planes.firstOrNull { it.index == 1 } ?: return
        val v = frame.planes.firstOrNull { it.index == 2 } ?: return
        val uvWidth = eyeWidth / 2
        val uvHeight = eyeHeight / 2
        val uBytes = u.bytes
        val vBytes = v.bytes
        val uRowStride = u.rowStride
        val vRowStride = v.rowStride
        val uPixelStride = u.pixelStride
        val vPixelStride = v.pixelStride

        if (uPixelStride == 2 && vPixelStride == 2 && uRowStride == vRowStride) {
            when (frame.chromaLayout) {
                ChromaLayout.NV12 -> {
                    if (copySemiPlanarChromaRows(uBytes, uvWidth, uvHeight, uRowStride, dst, dstOffset, dstStride, dstX, false)) {
                        return
                    }
                }
                ChromaLayout.NV21 -> {
                    if (copySemiPlanarChromaRows(vBytes, uvWidth, uvHeight, vRowStride, dst, dstOffset, dstStride, dstX, true)) {
                        return
                    }
                }
                ChromaLayout.UNKNOWN -> {
                }
            }
        }

        interleaveEyeUvFromPlanes(
            uBytes,
            vBytes,
            uRowStride,
            vRowStride,
            uPixelStride,
            vPixelStride,
            uvWidth,
            uvHeight,
            dst,
            dstOffset,
            dstStride,
            dstX
        )
    }

    private fun copySemiPlanarChromaRows(
        src: ByteArray,
        uvWidth: Int,
        uvHeight: Int,
        srcRowStride: Int,
        dst: ByteArray,
        dstOffset: Int,
        dstStride: Int,
        dstX: Int,
        swapPairs: Boolean
    ): Boolean {
        val rowBytes = uvWidth * 2
        for (y in 0 until uvHeight) {
            val srcRow = y * srcRowStride
            val dstRow = dstOffset + y * dstStride + dstX
            if (src.size - srcRow < rowBytes || dst.size - dstRow < rowBytes) {
                return false
            }
        }
        for (y in 0 until uvHeight) {
            val srcRow = y * srcRowStride
            val dstRow = dstOffset + y * dstStride + dstX
            if (!swapPairs) {
                System.arraycopy(src, srcRow, dst, dstRow, rowBytes)
                continue
            }
            var srcIdx = srcRow
            var dstIdx = dstRow
            var x = 0
            while (x < rowBytes) {
                dst[dstIdx] = src[srcIdx + 1]
                dst[dstIdx + 1] = src[srcIdx]
                srcIdx += 2
                dstIdx += 2
                x += 2
            }
        }
        return true
    }

    // Generic source: pull one U byte and one V byte per chroma sample.
    // Bounds are hoisted to keep the inner loop tight.
    private fun interleaveEyeUvFromPlanes(
        uBytes: ByteArray,
        vBytes: ByteArray,
        uRowStride: Int,
        vRowStride: Int,
        uPixelStride: Int,
        vPixelStride: Int,
        uvWidth: Int,
        uvHeight: Int,
        dst: ByteArray,
        dstOffset: Int,
        dstStride: Int,
        dstX: Int
    ) {
        for (y in 0 until uvHeight) {
            val uRow = y * uRowStride
            val vRow = y * vRowStride
            val dstRow = dstOffset + y * dstStride + dstX
            val maxByU = if (uPixelStride > 0) (uBytes.size - uRow + uPixelStride - 1) / uPixelStride else 0
            val maxByV = if (vPixelStride > 0) (vBytes.size - vRow + vPixelStride - 1) / vPixelStride else 0
            val maxByDst = (dst.size - dstRow) / 2
            val rowLimit = minOf(uvWidth, maxByU, maxByV, maxByDst)
            var uIdx = uRow
            var vIdx = vRow
            var dstIdx = dstRow
            var x = 0
            while (x < rowLimit) {
                dst[dstIdx] = uBytes[uIdx]
                dst[dstIdx + 1] = vBytes[vIdx]
                uIdx += uPixelStride
                vIdx += vPixelStride
                dstIdx += 2
                x += 1
            }
        }
    }

    private fun chooseHevcEncoder(): MediaCodecInfo {
        val codecList = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        return codecList.codecInfos.firstOrNull { info ->
            info.isEncoder && info.supportedTypes.any { it.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, ignoreCase = true) }
        } ?: throw IllegalStateException("No HEVC encoder is available")
    }

    private fun chooseColorFormat(info: MediaCodecInfo): Int {
        val capabilities = info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_HEVC)
        val preferred = listOf(
            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Planar,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
        )
        return preferred.firstOrNull { capabilities.colorFormats.contains(it) }
            ?: capabilities.colorFormats.firstOrNull()
            ?: MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
    }

    private fun ByteBuffer.toByteArray(): ByteArray {
        val copy = slice()
        val out = ByteArray(copy.remaining())
        copy.get(out)
        return out
    }

    companion object {
        private const val TAG = "StereoHevcEncoder"
        private const val MAX_PAIR_DELTA_NS = 10_000_000L
        private const val AV_PKT_FLAG_KEY = 0x0001
    }
}
