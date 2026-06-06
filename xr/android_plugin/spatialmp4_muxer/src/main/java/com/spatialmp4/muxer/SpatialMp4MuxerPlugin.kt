// SpatialMP4 muxer plugin: Godot singleton that owns the libspatialmp4_writer
// native handle and implements SpatialDataSink. Stage 2b+c moves the entire
// muxer-side surface out of QuestCapturePlugin -- this plugin now provides:
//
//   * SpatialDataSink::startSession / finishSession (Kotlin contract, called
//     from the provider once it has resolved paths + camera side data).
//   * @UsedByGodot writeDepthFrame / writeHeadPose / writeControllerPose /
//     writeHandJointsPayload / writeControllerInput / finishSpatialMp4 /
//     popMuxerMetricsJson  -- GDScript callers (session_spool_writer.gd)
//     switch from QuestCapturePlugin to this singleton.
//   * SpatialDataSink::onRgbCsd / onRgbPacket   -- the RGB hot path. The
//     provider's StereoHevcEncoder now writes through these instead of
//     calling SpatialMp4Native.nativeWriteHevcPacket itself.
//
// Threading: the same native writer's IO thread serialises every packet
// write, so this class only needs to forward; concurrent calls from the
// MediaCodec encoder thread + the OpenXR depth callback + GDScript pose
// signals are already safe at the JNI / FFmpeg layer.

package com.spatialmp4.muxer

import android.util.Log
import com.spatialmp4.contract.AudioStreamConfig
import com.spatialmp4.contract.CONTRACT_VERSION
import com.spatialmp4.contract.Intrinsics
import com.spatialmp4.contract.RgbStreamConfig
import com.spatialmp4.contract.SessionConfig
import com.spatialmp4.contract.SpatialDataSink
import com.spatialmp4.contract.SpatialDataSinkRegistry
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicLong
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONObject

class SpatialMp4MuxerPlugin(godot: Godot) : GodotPlugin(godot), SpatialDataSink {

    init {
        // Self-register into the Kotlin-side sink registry so providers can find
        // us without going through GDScript. The @UsedByGodot annotation
        // processor does not marshal arbitrary Godot Object arguments, so an
        // explicit bindMuxer(Object) RPC from GDScript cannot pass a sink ref
        // across plugins -- the registry is the contract-aligned escape hatch.
        activeSink = this
        SpatialDataSinkRegistry.register(this)
    }

    override fun getPluginName(): String = "SpatialMp4MuxerPlugin"

    // ---- session-scoped state (assigned in startSession, cleared in finish)
    @Volatile private var nativeWriterHandle: Long = 0L
    @Volatile private var depthStreamConfigured: Boolean = false
    @Volatile private var rgbConfigured: Boolean = false
    @Volatile private var lastDepthPtsUs: Long = 0L
    @Volatile private var finalMp4Path: String = ""

    // Per-stream enable flags carried over from SessionConfig. write*() methods
    // honour these so a session that disabled, say, depth still tolerates a
    // late depth packet without poking the native writer.
    @Volatile private var recordDepth: Boolean = true
    @Volatile private var recordHeadPose: Boolean = true
    @Volatile private var recordControllerPose: Boolean = true
    @Volatile private var recordHandData: Boolean = true
    @Volatile private var recordControllerInput: Boolean = true
    // v3: audio gating mirrors the depth/pose flags. recordAudio is the
    // host's "is the audio sink expected to run at all" bit; audioConfigured
    // flips after the muxer accepts the first AAC CSD from the provider.
    @Volatile private var recordAudio: Boolean = false
    @Volatile private var audioConfigured: Boolean = false

    // ---- write counters (atomic getAndSet -> popMuxerMetricsJson) ---------
    private val metricNativeWriteRgb = AtomicLong(0L)
    private val metricNativeWriteDepth = AtomicLong(0L)
    private val metricNativeWritePose = AtomicLong(0L)
    private val metricNativeWriteHand = AtomicLong(0L)
    private val metricNativeWriteControllerInput = AtomicLong(0L)
    // v3: audio writes. Non-zero when an enabled session is actually feeding
    // the encoder; zero proves the audio gate (recordAudio + audioConfigured)
    // is suppressing writes when expected.
    private val metricNativeWriteAudio = AtomicLong(0L)

    // =======================================================================
    // SpatialDataSink (contract)
    // =======================================================================

    override fun startSession(config: SessionConfig): Boolean {
        if (!SpatialMp4Native.isLoaded) {
            emitError("Native SpatialMP4 writer is not available")
            return false
        }
        if (nativeWriterHandle != 0L) {
            emitError("startSession called while a previous writer was still open")
            return false
        }
        val handle = SpatialMp4Native.nativeStart(
            config.partialPath,
            config.finalPath,
            config.sessionStartUnixUs,
            config.sessionStartGodotTicksUs,
            config.rgbWidth,
            config.rgbHeight,
            config.rgbFps,
            config.rgbCameraCount,
            config.depthExpected,
            config.headPoseExpected,
            config.controllerPoseExpected,
            config.handJointsExpected,
            config.controllerInputExpected,
            config.rgbIcam,
            config.rgbEcam,
            config.rgbDstr,
            config.deviceType,
            config.deviceModel,
            config.deviceManufacturer,
            config.audioExpected,
            config.audioChannelLayoutCode
        )
        if (handle == 0L) {
            emitError("Failed to start native SpatialMP4 writer")
            return false
        }
        nativeWriterHandle = handle
        finalMp4Path = config.finalPath
        depthStreamConfigured = false
        rgbConfigured = false
        audioConfigured = false
        lastDepthPtsUs = 0L
        recordDepth = config.depthExpected
        recordHeadPose = config.headPoseExpected
        recordControllerPose = config.controllerPoseExpected
        recordHandData = config.handJointsExpected
        recordControllerInput = config.controllerInputExpected
        recordAudio = config.audioExpected
        Log.i(TAG, "SpatialMP4 writer started -> ${config.finalPath} (audio=${config.audioExpected})")
        return true
    }

    override fun finishSession(): String {
        val handle = nativeWriterHandle
        if (handle == 0L) {
            return ""
        }
        val ok = SpatialMp4Native.nativeFinish(handle)
        if (!ok) {
            emitError("Failed to finalize SpatialMP4: ${SpatialMp4Native.nativeGetLastError(handle)}")
        }
        SpatialMp4Native.nativeClose(handle)
        nativeWriterHandle = 0L
        depthStreamConfigured = false
        rgbConfigured = false
        audioConfigured = false
        recordAudio = false
        val resolved = finalMp4Path
        finalMp4Path = ""
        return if (ok) resolved else ""
    }

    override fun onRgbCsd(config: RgbStreamConfig) {
        val handle = nativeWriterHandle
        if (handle == 0L) {
            Log.w(TAG, "onRgbCsd called before startSession; ignoring")
            return
        }
        if (rgbConfigured) return
        if (!SpatialMp4Native.nativeConfigureHevc(handle, config.csd)) {
            emitError("nativeConfigureHevc failed: ${SpatialMp4Native.nativeGetLastError(handle)}")
            return
        }
        rgbConfigured = true
    }

    override fun onRgbPacket(
        data: ByteBuffer,
        ptsNs: Long,
        durationNs: Long,
        isKeyframe: Boolean
    ) {
        val handle = nativeWriterHandle
        if (handle == 0L) return
        // The contract documents `data` as potentially a direct MediaCodec
        // ByteBuffer whose memory dies after this method returns. The current
        // JNI surface (nativeWriteHevcPacket) wants a ByteArray, so we copy
        // through one. A future contract revision can add a direct-buffer
        // variant on the JNI side; that change is mechanical and isolated.
        val bytes = ByteArray(data.remaining())
        data.get(bytes)
        val flags = if (isKeyframe) AV_PKT_FLAG_KEY else 0
        // Contract is in Godot ticks ns; nativeWriteHevcPacket wants µs. The
        // depth + pose write paths already convert; this one had been
        // forwarding ns straight through, shifting HEVC PTS by 3 decades.
        val ok = SpatialMp4Native.nativeWriteHevcPacket(
            handle, bytes, ptsNs / 1000L, durationNs / 1000L, flags
        )
        if (!ok) {
            emitError("nativeWriteHevcPacket failed: ${SpatialMp4Native.nativeGetLastError(handle)}")
            return
        }
        metricNativeWriteRgb.incrementAndGet()
    }

    override fun onDepthMetadata(width: Int, height: Int, intrinsics: Intrinsics) {
        val handle = nativeWriterHandle
        if (handle == 0L) {
            Log.w(TAG, "onDepthMetadata called before startSession; ignoring")
            return
        }
        if (depthStreamConfigured) return
        val icam = SpatialMp4SideDataPacker.packDoubles(
            listOf(intrinsics.fx, intrinsics.fy, intrinsics.cx, intrinsics.cy)
        )
        val ecam = SpatialMp4SideDataPacker.packDoubles(intrinsics.extrinsics3x4)
        val dstr = SpatialMp4SideDataPacker.packDoubles(List(Intrinsics.DISTORTION_MAX_LEN * 2) { 0.0 })
        if (!SpatialMp4Native.nativeConfigureDepth(handle, width, height, icam, ecam, dstr)) {
            emitError("nativeConfigureDepth failed: ${SpatialMp4Native.nativeGetLastError(handle)}")
            return
        }
        depthStreamConfigured = true
    }

    override fun onDepthFrame(payload: ByteArray, ptsNs: Long, durationNs: Long) {
        val handle = nativeWriterHandle
        if (handle == 0L) return
        val ptsUs = ptsNs / 1000L
        val effectiveDuration = if (durationNs > 0) {
            durationNs / 1000L
        } else if (lastDepthPtsUs > 0L && ptsUs > lastDepthPtsUs) {
            ptsUs - lastDepthPtsUs
        } else {
            DEFAULT_DEPTH_DURATION_US
        }
        lastDepthPtsUs = ptsUs
        if (!SpatialMp4Native.nativeWriteDepthPacket(handle, payload, ptsUs, effectiveDuration)) {
            emitError("nativeWriteDepthPacket failed: ${SpatialMp4Native.nativeGetLastError(handle)}")
            return
        }
        metricNativeWriteDepth.incrementAndGet()
    }

    // ---- v3 audio hot path -------------------------------------------------

    override fun onAudioCsd(config: AudioStreamConfig) {
        val handle = nativeWriterHandle
        if (handle == 0L) {
            Log.w(TAG, "onAudioCsd called before startSession; ignoring")
            return
        }
        if (!recordAudio) {
            // Session config did not request audio; a stray CSD arrived
            // anyway (e.g. provider misconfiguration). Drop silently rather
            // than allocate a phantom track in the mp4.
            return
        }
        if (audioConfigured) return
        if (!SpatialMp4Native.nativeConfigureAudio(
                handle,
                config.sampleRateHz,
                config.channelCount,
                config.channelLayout.code,
                config.csd
            )
        ) {
            emitError("nativeConfigureAudio failed: ${SpatialMp4Native.nativeGetLastError(handle)}")
            onAudioUnavailable("native audio configuration failed")
            return
        }
        audioConfigured = true
        Log.i(
            TAG,
            "audio stream configured: ${config.sampleRateHz} Hz, " +
                "${config.channelCount} ch, layout=${config.channelLayout.tag}"
        )
    }

    override fun onAudioPacket(
        data: ByteBuffer,
        ptsNs: Long,
        durationNs: Long,
        isKeyframe: Boolean
    ) {
        val handle = nativeWriterHandle
        if (handle == 0L || !recordAudio) return
        if (!audioConfigured) return
        // The contract documents `data` as potentially a direct MediaCodec
        // ByteBuffer whose backing memory dies after this method returns;
        // copy through a ByteArray for the JNI hand-off. The encoder's
        // output buffer is small (≤ a few KB per AAC frame) so the copy
        // cost is negligible vs the HEVC packet path.
        val bytes = ByteArray(data.remaining())
        data.get(bytes)
        val flags = if (isKeyframe) AV_PKT_FLAG_KEY else 0
        val ok = SpatialMp4Native.nativeWriteAudioPacket(
            handle, bytes, ptsNs / 1000L, durationNs / 1000L, flags
        )
        if (!ok) {
            emitError("nativeWriteAudioPacket failed: ${SpatialMp4Native.nativeGetLastError(handle)}")
            return
        }
        metricNativeWriteAudio.incrementAndGet()
    }

    override fun onAudioUnavailable(reason: String) {
        val handle = nativeWriterHandle
        if (handle == 0L) return
        recordAudio = false
        audioConfigured = false
        if (!SpatialMp4Native.nativeDisableAudio(handle)) {
            emitError("nativeDisableAudio failed: ${SpatialMp4Native.nativeGetLastError(handle)}")
            return
        }
        Log.w(TAG, "audio disabled for active session: $reason")
    }

    override fun onError(message: String) {
        emitError(message)
    }

    // =======================================================================
    // GDScript-facing @UsedByGodot surface (moved from QuestCapturePlugin)
    // =======================================================================

    /** GDScript-side mirror of [SpatialDataSink.contractVersion]. */
    @UsedByGodot
    fun getMuxerContractVersion(): Int = CONTRACT_VERSION

    /** GDScript wrapper for [finishSession] -- returns the final mp4 path. */
    @UsedByGodot
    fun finishSpatialMp4(): String = finishSession()

    /**
     * GDScript-driven depth write. Provider's depth_sampler.gd computes the
     * payload + FOV and calls this directly; the equivalent Kotlin path for
     * future Kotlin-side depth sources is [SpatialDataSink.onDepthFrame] +
     * [SpatialDataSink.onDepthMetadata].
     */
    @UsedByGodot
    fun writeDepthFrame(
        timestampNs: Long,
        width: Int,
        height: Int,
        payloadU16Mm: ByteArray,
        fovLeft: Double,
        fovRight: Double,
        fovTop: Double,
        fovBottom: Double
    ): Boolean {
        val handle = nativeWriterHandle
        if (handle == 0L || payloadU16Mm.isEmpty()) {
            return false
        }
        if (!recordDepth) {
            return true
        }
        metricNativeWriteDepth.incrementAndGet()
        if (!depthStreamConfigured) {
            if (fovLeft <= 0.0 || fovRight <= 0.0 || fovTop <= 0.0 || fovBottom <= 0.0) {
                emitError("Depth FOV metadata is invalid; dropping depth stream")
                return false
            }
            val sideData = SpatialMp4SideDataPacker.packDepth(width, height, fovLeft, fovRight, fovTop, fovBottom)
            if (!SpatialMp4Native.nativeConfigureDepth(
                    handle, width, height, sideData.icam, sideData.ecam, sideData.dstr
                )
            ) {
                emitError("Failed to configure depth stream: ${SpatialMp4Native.nativeGetLastError(handle)}")
                return false
            }
            depthStreamConfigured = true
        }
        val ptsUs = timestampNs / 1000L
        val durationUs = if (lastDepthPtsUs > 0L && ptsUs > lastDepthPtsUs) {
            ptsUs - lastDepthPtsUs
        } else {
            DEFAULT_DEPTH_DURATION_US
        }
        lastDepthPtsUs = ptsUs
        val ok = SpatialMp4Native.nativeWriteDepthPacket(handle, payloadU16Mm, ptsUs, durationUs)
        if (!ok) {
            emitError("Failed to write depth packet: ${SpatialMp4Native.nativeGetLastError(handle)}")
        }
        return ok
    }

    @UsedByGodot
    fun writeHeadPose(
        timestampNs: Long,
        px: Double, py: Double, pz: Double,
        qx: Double, qy: Double, qz: Double, qw: Double,
        trackingValid: Boolean
    ): Boolean {
        val handle = nativeWriterHandle
        if (handle == 0L || !recordHeadPose || !trackingValid) return false
        metricNativeWritePose.incrementAndGet()
        val ok = SpatialMp4Native.nativeWriteHeadPose(
            handle, timestampNs / 1000L, DEFAULT_POSE_DURATION_US,
            px, py, pz, qx, qy, qz, qw
        )
        if (!ok) emitError("Failed to write head pose packet: ${SpatialMp4Native.nativeGetLastError(handle)}")
        return ok
    }

    @UsedByGodot
    fun writeControllerPose(
        source: String,
        timestampNs: Long,
        px: Double, py: Double, pz: Double,
        qx: Double, qy: Double, qz: Double, qw: Double,
        trackingValid: Boolean
    ): Boolean {
        val handle = nativeWriterHandle
        if (handle == 0L || !recordControllerPose || !trackingValid) return false
        val trackId = controllerPoseTrackId(source) ?: return false
        metricNativeWritePose.incrementAndGet()
        val ok = SpatialMp4Native.nativeWriteRigidPose(
            handle, trackId, timestampNs / 1000L, DEFAULT_POSE_DURATION_US,
            px, py, pz, qx, qy, qz, qw
        )
        if (!ok) emitError("Failed to write controller pose packet: ${SpatialMp4Native.nativeGetLastError(handle)}")
        return ok
    }

    @UsedByGodot
    fun writeHandJointsPayload(hand: String, timestampNs: Long, payload: ByteArray): Boolean {
        val handle = nativeWriterHandle
        if (handle == 0L || !recordHandData || payload.isEmpty()) return false
        val trackId = handTrackId(hand) ?: return false
        metricNativeWriteHand.incrementAndGet()
        val ok = SpatialMp4Native.nativeWriteTimedMetadata(
            handle, trackId, payload, timestampNs / 1000L, DEFAULT_HAND_DURATION_US
        )
        if (!ok) emitError("Failed to write hand joints packet: ${SpatialMp4Native.nativeGetLastError(handle)}")
        return ok
    }

    @UsedByGodot
    fun writeControllerInput(
        controller: String,
        timestampNs: Long,
        packetType: Int,
        availableMask: Long,
        pressedMask: Long,
        touchedMask: Long,
        changedMask: Long,
        triggerValue: Double,
        gripValue: Double,
        thumbstickX: Double,
        thumbstickY: Double,
        trackpadX: Double,
        trackpadY: Double
    ): Boolean {
        val handle = nativeWriterHandle
        if (handle == 0L || !recordControllerInput) return false
        val trackId = controllerInputTrackId(controller) ?: return false
        val controllerId = if (trackId == TRACK_LEFT_CONTROLLER_INPUT) 0 else 1
        val payload = packControllerInputPayload(
            packetType, controllerId,
            availableMask, pressedMask, touchedMask, changedMask,
            triggerValue.toFloat(), gripValue.toFloat(),
            thumbstickX.toFloat(), thumbstickY.toFloat(),
            trackpadX.toFloat(), trackpadY.toFloat()
        )
        metricNativeWriteControllerInput.incrementAndGet()
        val ok = SpatialMp4Native.nativeWriteTimedMetadata(
            handle, trackId, payload, timestampNs / 1000L, DEFAULT_INPUT_DURATION_US
        )
        if (!ok) emitError("Failed to write controller input packet: ${SpatialMp4Native.nativeGetLastError(handle)}")
        return ok
    }

    /**
     * Resets and snapshots the per-session native-write counters as JSON.
     * Mirrors the muxer-side subset of QuestCapturePlugin's old popMetricsJson;
     * the provider now publishes its own counters (camera frames, encoder
     * packets) under popMetricsJson without overlap.
     */
    @UsedByGodot
    fun popMuxerMetricsJson(): String {
        val payload = JSONObject()
            .put("native_rgb_writes", metricNativeWriteRgb.getAndSet(0L))
            .put("native_depth_writes", metricNativeWriteDepth.getAndSet(0L))
            .put("native_pose_writes", metricNativeWritePose.getAndSet(0L))
            .put("native_hand_writes", metricNativeWriteHand.getAndSet(0L))
            .put("native_input_writes", metricNativeWriteControllerInput.getAndSet(0L))
            .put("native_audio_writes", metricNativeWriteAudio.getAndSet(0L))
        return payload.toString()
    }

    // ---- helpers (private; copied verbatim from the old QuestCapturePlugin)

    private fun packControllerInputPayload(
        packetType: Int,
        controller: Int,
        availableMask: Long,
        pressedMask: Long,
        touchedMask: Long,
        changedMask: Long,
        triggerValue: Float,
        gripValue: Float,
        thumbstickX: Float,
        thumbstickY: Float,
        trackpadX: Float,
        trackpadY: Float
    ): ByteArray {
        val buffer = ByteBuffer.allocate(CONTROLLER_INPUT_PAYLOAD_BYTES).order(ByteOrder.LITTLE_ENDIAN)
        buffer.putInt(CONTROLLER_INPUT_MAGIC)
        buffer.putShort(1.toShort())
        buffer.putShort(packetType.toShort())
        buffer.putShort(controller.toShort())
        buffer.putShort(0)
        buffer.putLong(availableMask)
        buffer.putLong(pressedMask)
        buffer.putLong(touchedMask)
        buffer.putLong(changedMask)
        buffer.putFloat(triggerValue)
        buffer.putFloat(gripValue)
        buffer.putFloat(thumbstickX)
        buffer.putFloat(thumbstickY)
        buffer.putFloat(trackpadX)
        buffer.putFloat(trackpadY)
        return buffer.array()
    }

    private fun controllerPoseTrackId(source: String): Int? = when (source) {
        "left", "left_controller" -> TRACK_LEFT_CONTROLLER_POSE
        "right", "right_controller" -> TRACK_RIGHT_CONTROLLER_POSE
        else -> null
    }

    private fun handTrackId(hand: String): Int? = when (hand) {
        "left", "left_hand" -> TRACK_LEFT_HAND_JOINTS
        "right", "right_hand" -> TRACK_RIGHT_HAND_JOINTS
        else -> null
    }

    private fun controllerInputTrackId(controller: String): Int? = when (controller) {
        "left", "left_controller", "left_controller_input" -> TRACK_LEFT_CONTROLLER_INPUT
        "right", "right_controller", "right_controller_input" -> TRACK_RIGHT_CONTROLLER_INPUT
        else -> null
    }

    private fun emitError(message: String) {
        Log.e(TAG, message)
        emitSignal("camera_error", message)
    }

    override fun getPluginSignals(): MutableSet<SignalInfo> = mutableSetOf(
        SignalInfo("camera_error", String::class.java)
    )

    companion object {
        private const val TAG = "SpatialMp4MuxerPlugin"

        /**
         * The most recently constructed SpatialMp4MuxerPlugin, exposed as a
         * Kotlin-side static so QuestCapturePlugin (in a sibling AAR but the
         * same Java package) can resolve its sink without round-tripping
         * through GDScript. The Godot runtime only creates a single instance
         * per process, so this is effectively the canonical SpatialDataSink
         * for the current capture session.
         */
        @JvmStatic
        @Volatile
        var activeSink: SpatialDataSink? = null
            private set

        // Mirror libavcodec's AV_PKT_FLAG_KEY value so the provider doesn't
        // need to import its own copy when calling onRgbPacket.
        const val AV_PKT_FLAG_KEY: Int = 0x0001

        private const val DEFAULT_DEPTH_DURATION_US: Long = 200_000L
        private const val DEFAULT_POSE_DURATION_US: Long = 11_111L
        private const val DEFAULT_HAND_DURATION_US: Long = 33_333L
        private const val DEFAULT_INPUT_DURATION_US: Long = 1_000L

        private const val TRACK_HEAD_POSE = 0
        private const val TRACK_LEFT_CONTROLLER_POSE = 1
        private const val TRACK_RIGHT_CONTROLLER_POSE = 2
        private const val TRACK_LEFT_HAND_JOINTS = 3
        private const val TRACK_RIGHT_HAND_JOINTS = 4
        private const val TRACK_LEFT_CONTROLLER_INPUT = 5
        private const val TRACK_RIGHT_CONTROLLER_INPUT = 6

        private const val CONTROLLER_INPUT_PAYLOAD_BYTES = 68
        private const val CONTROLLER_INPUT_MAGIC = 0x504E4943
    }
}
