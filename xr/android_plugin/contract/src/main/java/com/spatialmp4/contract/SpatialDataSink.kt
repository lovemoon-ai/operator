// Cross-plugin contract for high-rate spatial capture data.
//
// Why this exists: RGB packets (HEVC at ~30 fps stereo) and depth frames (raw
// GRAY16LE at ~5 fps, ~200 KB each) need to flow from the provider plugin to
// the muxer plugin without round-tripping through GDScript Variants on every
// frame. The contract is a tiny Kotlin/JVM jar that both AARs depend on, so a
// provider can invoke `SpatialDataSink.onRgbPacket(...)` on the muxer's
// implementation directly via a normal Kotlin method call.
//
// Lifecycle / threading:
//   * Configuration calls (onRgbCsd, onDepthMetadata) happen once per session
//     on the provider's setup thread. Implementations must be re-entrant w.r.t.
//     a single thread but need not be thread-safe across configure calls.
//   * onRgbPacket / onDepthFrame are called on the producer's encoder thread
//     (MediaCodec output thread or the OpenXR depth callback's deferred queue).
//     Implementations should enqueue and return quickly (the current muxer's
//     IO thread already does exactly this).
//   * ByteBuffers passed to onRgbPacket are typically direct MediaCodec output
//     buffers whose backing memory is valid only until the call returns; the
//     sink MUST copy out before suspending.
//
// Versioning: append-only. New methods get a `default` implementation so older
// muxers stay compatible with newer providers and vice versa. Bump
// CONTRACT_VERSION on every API surface change; sinks override
// `contractVersion` to declare which revision they implement, and the host can
// reject mismatches at bind time.
//
// What is intentionally NOT here: low-rate streams (head/controller/hand
// pose, controller input) flow through plain GDScript signals -- the per-frame
// payload is tiny and the GDScript convenience is worth the variant cost. This
// contract is reserved for the bytes-per-second hot paths.

package com.spatialmp4.contract

import java.nio.ByteBuffer

// Bumped to 2 alongside Stage 2b: startSession / finishSession added so the
// muxer owns the native writer handle outright. Older sinks (v1) lack those
// hooks and silently no-op; binding still succeeds with a logged warning.
//
// Note: the device-identity fields on SessionConfig (deviceType / deviceModel
// / deviceManufacturer) are additive with default empty-string values, so
// they don't require a contract bump -- a provider built against an older
// SessionConfig still type-checks against this version, and an older muxer
// reading a newer SessionConfig just sees empty strings it skips writing.
const val CONTRACT_VERSION: Int = 2

/**
 * Per-camera intrinsics + extrinsics + lens distortion, used both for RGB
 * cameras and the depth sensor. `extrinsics3x4` is a 12-element row-major
 * matrix (identity = 1,0,0,0, 0,1,0,0, 0,0,1,0). `distortion` carries up to 5
 * Brown coefficients; pad with zeros when the sensor reports fewer.
 *
 * Width/height refer to the sensor itself (e.g. 320x320 for Quest 3 env depth);
 * the muxer uses them when packing per-stream metadata boxes.
 */
data class Intrinsics(
    val fx: Double,
    val fy: Double,
    val cx: Double,
    val cy: Double,
    val extrinsics3x4: List<Double>,
    val distortion: List<Double>,
    val width: Int,
    val height: Int
) {
    init {
        require(extrinsics3x4.size == EXTRINSICS_LEN) {
            "extrinsics3x4 must have $EXTRINSICS_LEN entries, got ${extrinsics3x4.size}"
        }
        require(distortion.size <= DISTORTION_MAX_LEN) {
            "distortion may have at most $DISTORTION_MAX_LEN entries, got ${distortion.size}"
        }
    }

    companion object {
        const val EXTRINSICS_LEN: Int = 12
        const val DISTORTION_MAX_LEN: Int = 5
        val IDENTITY_EXTRINSICS: List<Double> = listOf(
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0
        )
    }
}

/**
 * Whole-session description handed to [SpatialDataSink.startSession] once per
 * capture. Provider-side code (Camera2 + HEVC encoder + storage helper) is
 * responsible for resolving the output paths, the per-camera intrinsics, and
 * the master clock anchors before invoking; the muxer treats this as an
 * opaque "start the writer with these parameters" message and never reads
 * back any of these fields afterwards.
 */
data class SessionConfig(
    val partialPath: String,
    val finalPath: String,
    val sessionStartUnixUs: Long,
    val sessionStartGodotTicksUs: Long,
    val rgbWidth: Int,
    val rgbHeight: Int,
    val rgbFps: Int,
    val rgbCameraCount: Int,
    val depthExpected: Boolean,
    val headPoseExpected: Boolean,
    val controllerPoseExpected: Boolean,
    val handJointsExpected: Boolean,
    val controllerInputExpected: Boolean,
    val rgbIcam: ByteArray,
    val rgbEcam: ByteArray,
    val rgbDstr: ByteArray,
    // Device identity, captured at session start so every produced mp4 carries
    // the headset model in its moov/udta metadata. `deviceType` is the
    // normalised short id ("pico4_ultra" / "quest3" / "quest3s" / ...), while
    // the raw Build.MODEL / Build.MANUFACTURER strings are forwarded verbatim
    // for tooling that prefers them. Empty strings are tolerated; the muxer
    // simply skips writing the corresponding metadata key.
    val deviceType: String = "",
    val deviceModel: String = "",
    val deviceManufacturer: String = ""
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is SessionConfig) return false
        return partialPath == other.partialPath &&
            finalPath == other.finalPath &&
            sessionStartUnixUs == other.sessionStartUnixUs &&
            sessionStartGodotTicksUs == other.sessionStartGodotTicksUs &&
            rgbWidth == other.rgbWidth &&
            rgbHeight == other.rgbHeight &&
            rgbFps == other.rgbFps &&
            rgbCameraCount == other.rgbCameraCount &&
            depthExpected == other.depthExpected &&
            headPoseExpected == other.headPoseExpected &&
            controllerPoseExpected == other.controllerPoseExpected &&
            handJointsExpected == other.handJointsExpected &&
            controllerInputExpected == other.controllerInputExpected &&
            rgbIcam.contentEquals(other.rgbIcam) &&
            rgbEcam.contentEquals(other.rgbEcam) &&
            rgbDstr.contentEquals(other.rgbDstr) &&
            deviceType == other.deviceType &&
            deviceModel == other.deviceModel &&
            deviceManufacturer == other.deviceManufacturer
    }

    override fun hashCode(): Int {
        var result = partialPath.hashCode()
        result = 31 * result + finalPath.hashCode()
        result = 31 * result + sessionStartUnixUs.hashCode()
        result = 31 * result + sessionStartGodotTicksUs.hashCode()
        result = 31 * result + rgbWidth
        result = 31 * result + rgbHeight
        result = 31 * result + rgbFps
        result = 31 * result + rgbCameraCount
        result = 31 * result + depthExpected.hashCode()
        result = 31 * result + headPoseExpected.hashCode()
        result = 31 * result + controllerPoseExpected.hashCode()
        result = 31 * result + handJointsExpected.hashCode()
        result = 31 * result + controllerInputExpected.hashCode()
        result = 31 * result + rgbIcam.contentHashCode()
        result = 31 * result + rgbEcam.contentHashCode()
        result = 31 * result + rgbDstr.contentHashCode()
        result = 31 * result + deviceType.hashCode()
        result = 31 * result + deviceModel.hashCode()
        result = 31 * result + deviceManufacturer.hashCode()
        return result
    }
}

/**
 * One-shot RGB stream description, emitted as soon as the encoder produces its
 * codec-specific data (HEVC vps/sps/pps blob in `csd`). `cameras` carries one
 * Intrinsics per camera, in stereo SBS order (left, right).
 */
data class RgbStreamConfig(
    val width: Int,
    val height: Int,
    val fps: Int,
    val cameras: List<Intrinsics>,
    val csd: ByteArray
) {
    val camCount: Int get() = cameras.size

    // ByteArray equality is reference-based in data classes; override to value
    // equality so unit tests / golden comparisons behave intuitively.
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is RgbStreamConfig) return false
        return width == other.width &&
            height == other.height &&
            fps == other.fps &&
            cameras == other.cameras &&
            csd.contentEquals(other.csd)
    }

    override fun hashCode(): Int {
        var result = width
        result = 31 * result + height
        result = 31 * result + fps
        result = 31 * result + cameras.hashCode()
        result = 31 * result + csd.contentHashCode()
        return result
    }
}

/**
 * The data interface a muxer (or any other consumer) implements; providers
 * invoke these methods directly across the Kotlin boundary, no Variant hop.
 *
 * `ptsNs` is always in the Godot ticks ns domain
 * (see [com.spatialmp4.contract.PtsDomain]). Providers are responsible for
 * folding XR / sensor clocks into this single domain.
 */
interface SpatialDataSink {
    /** Implementations override to declare which contract revision they speak. */
    val contractVersion: Int
        get() = CONTRACT_VERSION

    // ---- session lifecycle ------------------------------------------------

    /**
     * Stand up the underlying muxer (e.g. open the mp4 output, allocate the
     * native writer handle) using the resolved capture parameters. Returns
     * true on success; on false the sink must have logged via onError().
     * Default no-op so older v1 sinks remain bind-compatible (with a warning).
     */
    fun startSession(config: SessionConfig): Boolean = false

    /**
     * Drain and finalise the session. Returns the absolute path of the
     * produced asset, or an empty string on failure. Default no-op for v1
     * compatibility -- v2+ sinks must implement this for finishSession to
     * be a no-fallback path.
     */
    fun finishSession(): String = ""

    // ---- one-shot configuration -------------------------------------------

    /** Called once when the RGB encoder emits its codec-specific data. */
    fun onRgbCsd(config: RgbStreamConfig)

    /** Called once when the depth stream's first frame establishes its geometry. */
    fun onDepthMetadata(width: Int, height: Int, intrinsics: Intrinsics)

    // ---- hot streams -------------------------------------------------------

    /**
     * One encoded RGB packet. `data` is typically a direct ByteBuffer aliased
     * to a MediaCodec output buffer whose memory becomes invalid the moment
     * this call returns -- copy out before deferring work.
     */
    fun onRgbPacket(
        data: ByteBuffer,
        ptsNs: Long,
        durationNs: Long,
        isKeyframe: Boolean
    )

    /**
     * One depth frame's worth of bytes in the layout the muxer wants to
     * encode (today: GRAY16LE millimetres). The byte array is owned by the
     * provider but the sink is free to retain a reference -- the provider
     * does not reuse the buffer.
     */
    fun onDepthFrame(
        payload: ByteArray,
        ptsNs: Long,
        durationNs: Long
    )

    // ---- optional hooks ----------------------------------------------------

    /** Forwarded by the provider so the host can show a single error path. */
    fun onError(message: String) {}
}

/**
 * Canonical name of the timebase that every `ptsNs` in this contract uses.
 * Documenting it here saves every downstream from having to rediscover the
 * mapping; see [SpatialDataSink] for usage.
 */
object PtsDomain {
    const val NAME: String = "godot_ticks_ns"
    const val UNITS_PER_SECOND: Long = 1_000_000_000L
}
