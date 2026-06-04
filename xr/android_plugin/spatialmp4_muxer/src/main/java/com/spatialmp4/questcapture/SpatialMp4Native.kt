package com.spatialmp4.questcapture

import android.util.Log

object SpatialMp4Native {
    private const val TAG = "SpatialMp4Native"

    val isLoaded: Boolean = try {
        System.loadLibrary("spatialmp4_writer")
        true
    } catch (error: UnsatisfiedLinkError) {
        Log.e(TAG, "Failed to load spatialmp4_writer", error)
        false
    }

    external fun nativeStart(
        partialPath: String,
        finalPath: String,
        sessionStartUnixUs: Long,
        sessionStartGodotTicksUs: Long,
        rgbWidth: Int,
        rgbHeight: Int,
        rgbFps: Int,
        rgbCameraCount: Int,
        depthExpected: Boolean,
        headPoseExpected: Boolean,
        controllerPoseExpected: Boolean,
        handJointsExpected: Boolean,
        controllerInputExpected: Boolean,
        rgbIcam: ByteArray,
        rgbEcam: ByteArray,
        rgbDstr: ByteArray,
        deviceType: String,
        deviceModel: String,
        deviceManufacturer: String,
        // v3: audio stream gating. When `audioExpected` is true, the writer
        // defers header emission until nativeConfigureAudio has been called
        // (same shape as depth: configure-then-write). audioChannelLayoutCode
        // mirrors AudioChannelLayout.code on the contract side and is stored
        // verbatim into the audio track's `spatial_format` metadata key.
        audioExpected: Boolean,
        audioChannelLayoutCode: Int
    ): Long

    external fun nativeConfigureHevc(handle: Long, csd: ByteArray): Boolean
    external fun nativeConfigureDepth(
        handle: Long,
        width: Int,
        height: Int,
        depthIcam: ByteArray,
        depthEcam: ByteArray,
        depthDstr: ByteArray
    ): Boolean

    // v3: AAC stream configuration. `csd` is the AudioSpecificConfig blob
    // that MediaCodec emits as csd-0 on its first output frame. sample_rate
    // and channel_count are the values the encoder actually negotiated, which
    // may differ from what the provider requested (some devices clamp).
    external fun nativeConfigureAudio(
        handle: Long,
        sampleRateHz: Int,
        channelCount: Int,
        channelLayoutCode: Int,
        csd: ByteArray
    ): Boolean

    // v3: clear a pending audio gate when the provider cannot start or
    // configure AAC after SessionConfig.audioExpected=true. This lets RGB,
    // depth, and timed metadata continue without waiting forever for CSD.
    external fun nativeDisableAudio(handle: Long): Boolean

    external fun nativeWriteHevcPacket(
        handle: Long,
        data: ByteArray,
        ptsUs: Long,
        durationUs: Long,
        flags: Int
    ): Boolean

    external fun nativeWriteDepthPacket(
        handle: Long,
        data: ByteArray,
        ptsUs: Long,
        durationUs: Long
    ): Boolean

    // v3: encoded AAC packet. PTS in microseconds in the same Godot-ticks
    // domain as HEVC/depth/pose. Flags use libavcodec's AV_PKT_FLAG_* bit
    // layout (AV_PKT_FLAG_KEY = 0x0001); MediaCodec keys every AAC frame so
    // the provider can pass it unconditionally.
    external fun nativeWriteAudioPacket(
        handle: Long,
        data: ByteArray,
        ptsUs: Long,
        durationUs: Long,
        flags: Int
    ): Boolean

    external fun nativeWriteHeadPose(
        handle: Long,
        ptsUs: Long,
        durationUs: Long,
        px: Double,
        py: Double,
        pz: Double,
        qx: Double,
        qy: Double,
        qz: Double,
        qw: Double
    ): Boolean

    external fun nativeWriteRigidPose(
        handle: Long,
        trackId: Int,
        ptsUs: Long,
        durationUs: Long,
        px: Double,
        py: Double,
        pz: Double,
        qx: Double,
        qy: Double,
        qz: Double,
        qw: Double
    ): Boolean

    external fun nativeWriteTimedMetadata(
        handle: Long,
        trackId: Int,
        data: ByteArray,
        ptsUs: Long,
        durationUs: Long
    ): Boolean

    external fun nativeFinish(handle: Long): Boolean
    external fun nativeClose(handle: Long)
    external fun nativeGetLastError(handle: Long): String
}
