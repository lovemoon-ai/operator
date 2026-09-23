package com.spatialmp4.capturecommon

/**
 * Delivers at most one RGB frame per target interval out of a camera that runs
 * at the (faster) capture rate, so the delivered rate can change while a
 * capture runs: lowering it drops frames here instead of restarting the camera
 * and the encoder. The target can never exceed the capture rate.
 *
 * Frames are due on a fixed grid of target intervals, so a target that does
 * not divide the capture rate (20 of 30 fps) still averages to the target. A
 * frame up to 1/8 of an interval early counts as due, so capture jitter does
 * not drop frames when the target equals the capture rate.
 */
class RgbRateGate(private val captureFps: Int) {
    @Volatile
    private var intervalNs: Long = intervalFor(captureFps)
    @Volatile
    private var nextDueNs: Long = Long.MIN_VALUE

    /** Duration of one delivered frame, for packet timing. */
    val intervalUs: Long
        get() = intervalNs / 1_000L

    /** Returns false (and changes nothing) for a rate the camera cannot deliver. */
    fun setTargetFps(fps: Int): Boolean {
        if (fps <= 0 || fps > captureFps) {
            return false
        }
        intervalNs = intervalFor(fps)
        nextDueNs = Long.MIN_VALUE
        return true
    }

    fun accept(timestampNs: Long): Boolean {
        val interval = intervalNs
        val due = nextDueNs
        if (due != Long.MIN_VALUE && timestampNs < due - interval / 8) {
            return false
        }
        // Advance on the grid; resync after a gap longer than one interval.
        nextDueNs = if (due == Long.MIN_VALUE || timestampNs - due > interval) {
            timestampNs + interval
        } else {
            due + interval
        }
        return true
    }

    private companion object {
        fun intervalFor(fps: Int): Long = 1_000_000_000L / fps.coerceAtLeast(1)
    }
}
