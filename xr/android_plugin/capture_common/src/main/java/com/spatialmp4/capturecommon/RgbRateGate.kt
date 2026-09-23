package com.spatialmp4.capturecommon

/**
 * Delivers at most one RGB frame per target interval out of a camera that runs
 * at the (faster) capture rate, so the delivered rate can change while a
 * capture runs: lowering it drops frames here instead of restarting the camera
 * and the encoder. The target can never exceed the capture rate.
 *
 * Accepts a frame when it is at least 7/8 of an interval after the last
 * accepted one, so capture jitter does not drop frames when the target equals
 * the capture rate.
 */
class RgbRateGate(private val captureFps: Int) {
    @Volatile
    private var intervalNs: Long = intervalFor(captureFps)
    private var lastAcceptedNs: Long = Long.MIN_VALUE

    /** Duration of one delivered frame, for packet timing. */
    val intervalUs: Long
        get() = intervalNs / 1_000L

    /** Returns false (and changes nothing) for a rate the camera cannot deliver. */
    fun setTargetFps(fps: Int): Boolean {
        if (fps <= 0 || fps > captureFps) {
            return false
        }
        intervalNs = intervalFor(fps)
        return true
    }

    fun accept(timestampNs: Long): Boolean {
        val interval = intervalNs
        if (lastAcceptedNs != Long.MIN_VALUE && timestampNs - lastAcceptedNs < interval - interval / 8) {
            return false
        }
        lastAcceptedNs = timestampNs
        return true
    }

    private companion object {
        fun intervalFor(fps: Int): Long = 1_000_000_000L / fps.coerceAtLeast(1)
    }
}
