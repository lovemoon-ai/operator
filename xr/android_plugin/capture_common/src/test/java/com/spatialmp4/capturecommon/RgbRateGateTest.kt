package com.spatialmp4.capturecommon

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RgbRateGateTest {
    private fun accepted(gate: RgbRateGate, stepNs: Long, frames: Int, jitterNs: Long = 0): Int =
        (0 until frames).count { i ->
            val jitter = if (i % 2 == 0) jitterNs else -jitterNs
            gate.accept(i * stepNs + jitter)
        }

    @Test
    fun deliversEveryFrameAtTheCaptureRateDespiteJitter() {
        val gate = RgbRateGate(captureFps = 4)
        assertEquals(40, accepted(gate, 250_000_000L, 40, jitterNs = 10_000_000L))
    }

    @Test
    fun lowersTheDeliveredRateWithoutARestart() {
        val gate = RgbRateGate(captureFps = 4)
        assertTrue(gate.setTargetFps(1))
        // 40 camera frames at 4 fps span 10 s: one delivered per second.
        assertEquals(10, accepted(gate, 250_000_000L, 40))
        assertEquals(1_000_000L, gate.intervalUs)
    }

    @Test
    fun refusesRatesTheCameraCannotDeliver() {
        val gate = RgbRateGate(captureFps = 4)
        assertFalse(gate.setTargetFps(5))
        assertFalse(gate.setTargetFps(0))
        assertEquals(250_000L, gate.intervalUs)
    }

    @Test
    fun raisingTheRateBackTakesEffectImmediately() {
        val gate = RgbRateGate(captureFps = 4)
        gate.setTargetFps(1)
        assertTrue(gate.accept(0L))
        assertFalse(gate.accept(250_000_000L))
        gate.setTargetFps(4)
        assertTrue(gate.accept(500_000_000L))
        assertTrue(gate.accept(750_000_000L))
    }
}
