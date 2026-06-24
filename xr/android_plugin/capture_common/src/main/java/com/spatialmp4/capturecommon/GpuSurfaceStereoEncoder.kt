package com.spatialmp4.capturecommon

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.util.Log
import android.view.Surface
import com.spatialmp4.contract.Intrinsics
import com.spatialmp4.contract.RgbStreamConfig
import com.spatialmp4.contract.RgbVideoCodec
import com.spatialmp4.contract.SpatialDataSink
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.abs
import kotlin.math.max

data class CapturedRgbaFrame(
    val eye: String,
    val timestampNs: Long,
    val width: Int,
    val height: Int,
    val rowStride: Int,
    val pixelStride: Int,
    val bytes: ByteArray
)

/**
 * Surface-input MediaCodec encoder for XR_PICO_camera_image RGBA frames.
 *
 * This keeps the OpenXR RGB path out of the byte-buffer YUV encoder: RGBA
 * frames are uploaded as GL textures, stereo is composed side-by-side in GLES,
 * and MediaCodec consumes its input Surface directly.
 */
class GpuSurfaceStereoEncoder(
    private val dataSink: SpatialDataSink,
    private val eyeWidth: Int,
    private val eyeHeight: Int,
    private val fps: Int,
    private val bitrate: Int,
    private val stereo: Boolean,
    private val cameraIntrinsics: List<Intrinsics>,
    private val rgbCodec: String = RgbVideoCodec.HEVC.tag,
    private val onError: (String) -> Unit,
    private val onPairEncoded: () -> Unit = {},
    private val onMonoEncoded: () -> Unit = {},
    private val onPacketEmitted: () -> Unit = {}
) {
    private val frameDurationUs = 1_000_000L / max(fps, 1)
    private val normalizedCodec = RgbVideoCodec.normalize(rgbCodec)
    private val codecMimeType = mimeTypeForCodec(normalizedCodec)
    private val codecLabel = labelForCodec(normalizedCodec)
    private val encodedWidth = if (stereo) eyeWidth * 2 else eyeWidth
    private val encodedHeight = eyeHeight
    private val bufferInfo = MediaCodec.BufferInfo()

    private var codec: MediaCodec? = null
    private var inputSurface: Surface? = null
    private var pendingLeft: CapturedRgbaFrame? = null
    private var pendingRight: CapturedRgbaFrame? = null
    private var stopped = false
    private var lastPresentationTimeNs = Long.MIN_VALUE

    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var eglConfig: EGLConfig? = null
    private var glProgram = 0
    private var positionHandle = -1
    private var texCoordHandle = -1
    private var samplerHandle = -1
    private val textures = IntArray(2)
    private var compactRgba = ByteArray(0)

    private val vertexBuffer: FloatBuffer = floatBuffer(
        floatArrayOf(
            -1.0f, -1.0f,
            1.0f, -1.0f,
            -1.0f, 1.0f,
            1.0f, 1.0f
        )
    )
    private val texCoordBuffer: FloatBuffer = floatBuffer(
        floatArrayOf(
            0.0f, 1.0f,
            1.0f, 1.0f,
            0.0f, 0.0f,
            1.0f, 0.0f
        )
    )

    fun start(): Boolean {
        return try {
            val codecInfo = chooseSurfaceVideoEncoder(codecMimeType)
            val format = MediaFormat.createVideoFormat(codecMimeType, encodedWidth, encodedHeight)
            format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            format.setInteger(MediaFormat.KEY_COLOR_STANDARD, MediaFormat.COLOR_STANDARD_BT709)
            format.setInteger(MediaFormat.KEY_COLOR_TRANSFER, MediaFormat.COLOR_TRANSFER_SDR_VIDEO)
            format.setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_LIMITED)
            format.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            format.setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            format.setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)

            val localCodec = MediaCodec.createByCodecName(codecInfo.name)
            localCodec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            val surface = localCodec.createInputSurface()
            setupEgl(surface)
            setupGl()
            localCodec.start()
            codec = localCodec
            inputSurface = surface
            Log.i(TAG, "started GPU Surface $codecLabel encoder ${codecInfo.name} ${encodedWidth}x$encodedHeight stereo=$stereo fps=$fps bitrate=$bitrate colorspace=bt709/sdr/limited")
            true
        } catch (error: Exception) {
            onError("Failed to start GPU Surface $codecLabel encoder: ${error.message}")
            releaseCodecAndGl()
            false
        }
    }

    fun offer(frame: CapturedRgbaFrame): Boolean {
        if (stopped || codec == null) {
            return false
        }
        if (frame.width != eyeWidth || frame.height != eyeHeight) {
            onError("Dropping RGB frame with unexpected size ${frame.width}x${frame.height}")
            return false
        }
        if (!hasEnoughRgbaBytes(frame)) {
            onError("Dropping RGB frame with invalid RGBA buffer")
            return false
        }

        if (!stereo) {
            if (frame.eye == "left") {
                encodeMono(frame)
                onMonoEncoded()
                return true
            }
            return false
        }
        if (frame.eye == "right") {
            pendingRight = frame
        } else {
            pendingLeft = frame
        }
        encodeAvailablePair()
        return true
    }

    fun stopAndDrain() {
        if (stopped) {
            return
        }
        stopped = true
        val localCodec = codec
        if (localCodec == null) {
            releaseCodecAndGl()
            return
        }
        try {
            drainEncoder(false)
            localCodec.signalEndOfInputStream()
            drainEncoder(true)
        } catch (error: Exception) {
            onError("Failed to drain GPU Surface $codecLabel encoder: ${error.message}")
        } finally {
            releaseCodecAndGl()
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
            onPairEncoded()
        }
    }

    private fun encodeMono(frame: CapturedRgbaFrame) {
        encodeFrames(frame, null, frame.timestampNs)
    }

    private fun encodePair(left: CapturedRgbaFrame, right: CapturedRgbaFrame, timestampNs: Long) {
        encodeFrames(left, right, timestampNs)
    }

    private fun encodeFrames(left: CapturedRgbaFrame, right: CapturedRgbaFrame?, timestampNs: Long) {
        if (codec == null) return
        drainEncoder(false)
        makeCurrent()
        GLES20.glViewport(0, 0, encodedWidth, encodedHeight)
        GLES20.glClearColor(0.0f, 0.0f, 0.0f, 1.0f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        uploadTexture(textures[0], left)
        drawTexture(textures[0], 0, 0, eyeWidth, eyeHeight)
        if (stereo && right != null) {
            uploadTexture(textures[1], right)
            drawTexture(textures[1], eyeWidth, 0, eyeWidth, eyeHeight)
        }

        val presentationTimeNs = monotonicPresentationTimeNs(timestampNs)
        EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, presentationTimeNs)
        if (!EGL14.eglSwapBuffers(eglDisplay, eglSurface)) {
            throw IllegalStateException("eglSwapBuffers failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
        }
        drainEncoder(false)
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
                    configureNativeRgb(localCodec.outputFormat)
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

    private fun configureNativeRgb(format: MediaFormat) {
        val csd = collectCodecConfig(format)
        if (csd.isEmpty()) {
            onError("GPU Surface $codecLabel encoder output format did not include codec config")
            return
        }
        dataSink.onRgbCsd(
            RgbStreamConfig(
                width = encodedWidth,
                height = encodedHeight,
                fps = fps,
                cameras = cameraIntrinsics,
                csd = csd,
                codec = normalizedCodec
            )
        )
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
        val out = ByteArray(chunks.sumOf { it.size })
        var offset = 0
        for (chunk in chunks) {
            System.arraycopy(chunk, 0, out, offset, chunk.size)
            offset += chunk.size
        }
        return out
    }

    private fun setupEgl(surface: Surface) {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) {
            throw IllegalStateException("eglGetDisplay failed")
        }
        val version = IntArray(2)
        if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
            throw IllegalStateException("eglInitialize failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
        }

        val attribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
            EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        if (!EGL14.eglChooseConfig(eglDisplay, attribs, 0, configs, 0, configs.size, numConfigs, 0)) {
            throw IllegalStateException("eglChooseConfig failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
        }
        eglConfig = configs[0] ?: throw IllegalStateException("No EGL config available")

        val contextAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT, contextAttribs, 0)
        if (eglContext == EGL14.EGL_NO_CONTEXT) {
            throw IllegalStateException("eglCreateContext failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
        }
        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, eglConfig, surface, intArrayOf(EGL14.EGL_NONE), 0)
        if (eglSurface == EGL14.EGL_NO_SURFACE) {
            throw IllegalStateException("eglCreateWindowSurface failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
        }
        makeCurrent()
    }

    private fun setupGl() {
        glProgram = createProgram(VERTEX_SHADER, FRAGMENT_SHADER)
        positionHandle = GLES20.glGetAttribLocation(glProgram, "aPosition")
        texCoordHandle = GLES20.glGetAttribLocation(glProgram, "aTexCoord")
        samplerHandle = GLES20.glGetUniformLocation(glProgram, "uTexture")
        GLES20.glGenTextures(textures.size, textures, 0)
        for (texture in textures) {
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        }
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
    }

    private fun uploadTexture(texture: Int, frame: CapturedRgbaFrame) {
        val pixelStride = frame.pixelStride.coerceAtLeast(4)
        val rowStride = if (frame.rowStride > 0) frame.rowStride else frame.width * pixelStride
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture)
        GLES20.glPixelStorei(GLES20.GL_UNPACK_ALIGNMENT, 1)
        if (pixelStride == 4 && rowStride == frame.width * 4) {
            GLES20.glTexImage2D(
                GLES20.GL_TEXTURE_2D,
                0,
                GLES20.GL_RGBA,
                frame.width,
                frame.height,
                0,
                GLES20.GL_RGBA,
                GLES20.GL_UNSIGNED_BYTE,
                ByteBuffer.wrap(frame.bytes)
            )
        } else {
            GLES20.glTexImage2D(
                GLES20.GL_TEXTURE_2D,
                0,
                GLES20.GL_RGBA,
                frame.width,
                frame.height,
                0,
                GLES20.GL_RGBA,
                GLES20.GL_UNSIGNED_BYTE,
                ByteBuffer.wrap(compactRgba(frame, rowStride, pixelStride))
            )
        }
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
    }

    private fun compactRgba(frame: CapturedRgbaFrame, rowStride: Int, pixelStride: Int): ByteArray {
        val required = frame.width * frame.height * 4
        if (compactRgba.size < required) {
            compactRgba = ByteArray(required)
        }
        for (row in 0 until frame.height) {
            val srcRow = row * rowStride
            val dstRow = row * frame.width * 4
            if (pixelStride == 4) {
                val rowBytes = minOf(frame.width * 4, frame.bytes.size - srcRow, compactRgba.size - dstRow)
                if (rowBytes > 0) {
                    System.arraycopy(frame.bytes, srcRow, compactRgba, dstRow, rowBytes)
                }
            } else {
                var src = srcRow
                var dst = dstRow
                var col = 0
                while (col < frame.width && src + 2 < frame.bytes.size && dst + 3 < compactRgba.size) {
                    compactRgba[dst] = frame.bytes[src]
                    compactRgba[dst + 1] = frame.bytes[src + 1]
                    compactRgba[dst + 2] = frame.bytes[src + 2]
                    compactRgba[dst + 3] = if (src + 3 < frame.bytes.size) frame.bytes[src + 3] else 0xff.toByte()
                    src += pixelStride
                    dst += 4
                    col += 1
                }
            }
        }
        return compactRgba
    }

    private fun drawTexture(texture: Int, x: Int, y: Int, width: Int, height: Int) {
        GLES20.glViewport(x, y, width, height)
        GLES20.glUseProgram(glProgram)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, texture)
        GLES20.glUniform1i(samplerHandle, 0)
        vertexBuffer.position(0)
        GLES20.glEnableVertexAttribArray(positionHandle)
        GLES20.glVertexAttribPointer(positionHandle, 2, GLES20.GL_FLOAT, false, 0, vertexBuffer)
        texCoordBuffer.position(0)
        GLES20.glEnableVertexAttribArray(texCoordHandle)
        GLES20.glVertexAttribPointer(texCoordHandle, 2, GLES20.GL_FLOAT, false, 0, texCoordBuffer)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(positionHandle)
        GLES20.glDisableVertexAttribArray(texCoordHandle)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0)
    }

    private fun makeCurrent() {
        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            throw IllegalStateException("eglMakeCurrent failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
        }
    }

    private fun releaseCodecAndGl() {
        releaseGl()
        try {
            codec?.stop()
        } catch (_: Exception) {
        }
        codec?.release()
        codec = null
        inputSurface?.release()
        inputSurface = null
    }

    private fun releaseGl() {
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            try {
                if (eglContext != EGL14.EGL_NO_CONTEXT && eglSurface != EGL14.EGL_NO_SURFACE) {
                    EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
                    if (textures.any { it != 0 }) {
                        GLES20.glDeleteTextures(textures.size, textures, 0)
                    }
                    if (glProgram != 0) {
                        GLES20.glDeleteProgram(glProgram)
                    }
                }
                EGL14.eglMakeCurrent(
                    eglDisplay,
                    EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_CONTEXT
                )
                if (eglSurface != EGL14.EGL_NO_SURFACE) {
                    EGL14.eglDestroySurface(eglDisplay, eglSurface)
                }
                if (eglContext != EGL14.EGL_NO_CONTEXT) {
                    EGL14.eglDestroyContext(eglDisplay, eglContext)
                }
                EGL14.eglReleaseThread()
                EGL14.eglTerminate(eglDisplay)
            } catch (_: Exception) {
            }
        }
        textures[0] = 0
        textures[1] = 0
        glProgram = 0
        eglDisplay = EGL14.EGL_NO_DISPLAY
        eglContext = EGL14.EGL_NO_CONTEXT
        eglSurface = EGL14.EGL_NO_SURFACE
        eglConfig = null
    }

    private fun hasEnoughRgbaBytes(frame: CapturedRgbaFrame): Boolean {
        if (frame.width <= 0 || frame.height <= 0) return false
        val pixelStride = frame.pixelStride.coerceAtLeast(4)
        val rowStride = if (frame.rowStride > 0) frame.rowStride else frame.width * pixelStride
        val minRowBytes = (frame.width - 1L) * pixelStride + 4L
        if (rowStride < minRowBytes) return false
        val required = rowStride.toLong() * (frame.height - 1L) + minRowBytes
        return required <= frame.bytes.size
    }

    private fun monotonicPresentationTimeNs(timestampNs: Long): Long {
        val next = if (lastPresentationTimeNs == Long.MIN_VALUE || timestampNs > lastPresentationTimeNs) {
            timestampNs
        } else {
            lastPresentationTimeNs + 1_000L
        }
        lastPresentationTimeNs = next
        return next
    }

    private fun chooseSurfaceVideoEncoder(mimeType: String): MediaCodecInfo {
        val codecList = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        return codecList.codecInfos.firstOrNull { info ->
            if (!info.isEncoder || !info.supportedTypes.any { it.equals(mimeType, ignoreCase = true) }) {
                return@firstOrNull false
            }
            info.getCapabilitiesForType(mimeType)
                .colorFormats
                .contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        } ?: throw IllegalStateException("No Surface-input $codecLabel encoder is available")
    }

    private fun createProgram(vertexSource: String, fragmentSource: String): Int {
        val vertexShader = compileShader(GLES20.GL_VERTEX_SHADER, vertexSource)
        val fragmentShader = compileShader(GLES20.GL_FRAGMENT_SHADER, fragmentSource)
        val program = GLES20.glCreateProgram()
        GLES20.glAttachShader(program, vertexShader)
        GLES20.glAttachShader(program, fragmentShader)
        GLES20.glLinkProgram(program)
        val status = IntArray(1)
        GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(program)
            GLES20.glDeleteProgram(program)
            throw IllegalStateException("GL program link failed: $log")
        }
        GLES20.glDeleteShader(vertexShader)
        GLES20.glDeleteShader(fragmentShader)
        return program
    }

    private fun compileShader(type: Int, source: String): Int {
        val shader = GLES20.glCreateShader(type)
        GLES20.glShaderSource(shader, source)
        GLES20.glCompileShader(shader)
        val status = IntArray(1)
        GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, status, 0)
        if (status[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(shader)
            GLES20.glDeleteShader(shader)
            throw IllegalStateException("GL shader compile failed: $log")
        }
        return shader
    }

    private fun ByteBuffer.toByteArray(): ByteArray {
        val copy = slice()
        val out = ByteArray(copy.remaining())
        copy.get(out)
        return out
    }

    companion object {
        private const val TAG = "GpuSurfaceStereoEncoder"
        private const val MAX_PAIR_DELTA_NS = 10_000_000L

        private const val VERTEX_SHADER = """
            attribute vec4 aPosition;
            attribute vec2 aTexCoord;
            varying vec2 vTexCoord;
            void main() {
                gl_Position = aPosition;
                vTexCoord = aTexCoord;
            }
        """

        private const val FRAGMENT_SHADER = """
            precision mediump float;
            uniform sampler2D uTexture;
            varying vec2 vTexCoord;
            void main() {
                gl_FragColor = texture2D(uTexture, vTexCoord);
            }
        """

        private fun mimeTypeForCodec(codec: String): String =
            if (codec == RgbVideoCodec.H264.tag) {
                MediaFormat.MIMETYPE_VIDEO_AVC
            } else {
                MediaFormat.MIMETYPE_VIDEO_HEVC
            }

        private fun labelForCodec(codec: String): String =
            if (codec == RgbVideoCodec.H264.tag) "H.264" else "HEVC"

        private fun floatBuffer(values: FloatArray): FloatBuffer {
            val buffer = ByteBuffer
                .allocateDirect(values.size * java.lang.Float.BYTES)
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer()
            buffer.put(values)
            buffer.position(0)
            return buffer
        }
    }
}
