package com.ssrvpn.android

import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreLivenessMonitorTest {
    @Test
    fun `reports unexpected exit while the same start is active`() {
        assertTrue(
            CoreLivenessMonitor.waitForUnexpectedExit(
                startToken = 7,
                currentGeneration = { 7 },
                isRunning = { true },
                isBridgeRunning = { false }
            )
        )
    }

    @Test
    fun `ignores exit after a concurrent disconnect invalidates the start`() {
        val generation = AtomicLong(7)
        assertFalse(
            CoreLivenessMonitor.waitForUnexpectedExit(
                startToken = 7,
                currentGeneration = generation::get,
                isRunning = { true },
                isBridgeRunning = {
                    generation.incrementAndGet()
                    false
                }
            )
        )
    }

    @Test
    fun `does not report an already stopped session`() {
        assertFalse(
            CoreLivenessMonitor.waitForUnexpectedExit(
                startToken = 7,
                currentGeneration = { 7 },
                isRunning = { false },
                isBridgeRunning = { error("must not probe a stopped session") }
            )
        )
    }
}
