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
        deviceManufacturer: String
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
