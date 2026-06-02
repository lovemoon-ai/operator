package com.spatialmp4.questcapture

import org.json.JSONArray
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.sqrt

data class SpatialMp4SideData(
    val icam: ByteArray,
    val ecam: ByteArray,
    val dstr: ByteArray
)

object SpatialMp4SideDataPacker {
    fun packRgb(left: JSONObject, right: JSONObject?): SpatialMp4SideData {
        val cameras = listOfNotNull(normalizeCamera(left), right?.let(::normalizeCamera))
        return SpatialMp4SideData(
            icam = packDoubles(cameras.flatMap { listOf(it.fx, it.fy, it.cx, it.cy) }),
            ecam = packDoubles(cameras.flatMap { it.extrinsics }),
            dstr = packDoubles(cameras.flatMap { padDistortion(it.distortion, 5) })
        )
    }

    fun packDepth(width: Int, height: Int, left: Double, right: Double, top: Double, bottom: Double): SpatialMp4SideData {
        val fx = width.toDouble() / (left + right)
        val fy = height.toDouble() / (top + bottom)
        val cx = width.toDouble() * right / (left + right)
        val cy = height.toDouble() * top / (top + bottom)
        val identity = listOf(
            1.0, 0.0, 0.0, 0.0,
            0.0, 1.0, 0.0, 0.0,
            0.0, 0.0, 1.0, 0.0
        )
        return SpatialMp4SideData(
            icam = packDoubles(listOf(fx, fy, cx, cy)),
            ecam = packDoubles(identity),
            // The current SpatialMP4 FFmpeg reader expects two brown dstr coefficient sets for raw depth.
            dstr = packDoubles(List(10) { 0.0 })
        )
    }

    /**
     * Public mirror of `normalizeCamera` that returns the contract's
     * [com.spatialmp4.contract.Intrinsics] -- intended for the provider, which
     * extracts per-camera intrinsics from the Camera2 metadata JSON and hands
     * them to StereoHevcEncoder so it can build the RgbStreamConfig at CSD time.
     * Distortion is padded to DISTORTION_MAX_LEN with zeros (so the muxer's
     * downstream `dstr` box has the fixed shape it expects).
     */
    fun extractIntrinsics(
        metadata: JSONObject,
        width: Int,
        height: Int
    ): com.spatialmp4.contract.Intrinsics {
        val side = normalizeCamera(metadata)
        return com.spatialmp4.contract.Intrinsics(
            fx = side.fx,
            fy = side.fy,
            cx = side.cx,
            cy = side.cy,
            extrinsics3x4 = side.extrinsics,
            distortion = padDistortion(side.distortion, com.spatialmp4.contract.Intrinsics.DISTORTION_MAX_LEN),
            width = width,
            height = height
        )
    }

    private fun normalizeCamera(metadata: JSONObject): CameraSideData {
        val intrinsics = metadata.optJSONArray("lens_intrinsic_calibration").toDoubleList()
        val distortion = metadata.optJSONArray("lens_distortion").toDoubleList()
        val translation = metadata.optJSONArray("lens_pose_translation").toDoubleList()
        val rotation = metadata.optJSONArray("lens_pose_rotation").toDoubleList()
        return CameraSideData(
            fx = intrinsics.getOrElse(0) { 0.0 },
            fy = intrinsics.getOrElse(1) { 0.0 },
            cx = intrinsics.getOrElse(2) { 0.0 },
            cy = intrinsics.getOrElse(3) { 0.0 },
            distortion = distortion,
            extrinsics = quatTranslationTo3x4(rotation, translation)
        )
    }

    private fun quatTranslationTo3x4(rotation: List<Double>, translation: List<Double>): List<Double> {
        var x = rotation.getOrElse(0) { 0.0 }
        var y = rotation.getOrElse(1) { 0.0 }
        var z = rotation.getOrElse(2) { 0.0 }
        var w = rotation.getOrElse(3) { 1.0 }
        val norm = sqrt(x * x + y * y + z * z + w * w)
        if (norm == 0.0) {
            x = 0.0
            y = 0.0
            z = 0.0
            w = 1.0
        } else {
            x /= norm
            y /= norm
            z /= norm
            w /= norm
        }
        val tx = translation.getOrElse(0) { 0.0 }
        val ty = translation.getOrElse(1) { 0.0 }
        val tz = translation.getOrElse(2) { 0.0 }

        val xx = x * x
        val yy = y * y
        val zz = z * z
        val xy = x * y
        val xz = x * z
        val yz = y * z
        val wx = w * x
        val wy = w * y
        val wz = w * z
        return listOf(
            1.0 - 2.0 * (yy + zz), 2.0 * (xy - wz), 2.0 * (xz + wy), tx,
            2.0 * (xy + wz), 1.0 - 2.0 * (xx + zz), 2.0 * (yz - wx), ty,
            2.0 * (xz - wy), 2.0 * (yz + wx), 1.0 - 2.0 * (xx + yy), tz
        )
    }

    private fun padDistortion(values: List<Double>, count: Int): List<Double> {
        return List(count) { index -> values.getOrElse(index) { 0.0 } }
    }

    // Promoted from `private` so SpatialMp4MuxerPlugin (same package, different
    // gradle sub-module) can reuse the same packer when the SpatialDataSink
    // contract feeds it an Intrinsics it needs to ship as ICAM/ECAM/DSTR
    // side-data bytes. The wire layout is little-endian doubles.
    internal fun packDoubles(values: List<Double>): ByteArray {
        val buffer = ByteBuffer.allocate(values.size * java.lang.Double.BYTES)
            .order(ByteOrder.LITTLE_ENDIAN)
        values.forEach { buffer.putDouble(it) }
        return buffer.array()
    }

    private data class CameraSideData(
        val fx: Double,
        val fy: Double,
        val cx: Double,
        val cy: Double,
        val distortion: List<Double>,
        val extrinsics: List<Double>
    )
}

private fun JSONArray?.toDoubleList(): List<Double> {
    if (this == null) {
        return emptyList()
    }
    return List(length()) { index -> optDouble(index, 0.0) }
}
