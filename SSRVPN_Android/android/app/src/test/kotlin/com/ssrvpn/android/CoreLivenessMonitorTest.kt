package com.ssrvpn.android

import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.assertEquals
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

    @Test
    fun `reports a dead protect monitor while the bridge still reports running`() {
        assertTrue(
            CoreLivenessMonitor.waitForUnexpectedExit(
                startToken = 7,
                currentGeneration = { 7 },
                isRunning = { true },
                isBridgeRunning = { true },
                isProtectMonitorRunning = { false },
                isApiHealthy = { error("API must not be probed after protect failure") },
                sleep = { error("a dead protect monitor must fail immediately") }
            )
        )
    }

    @Test
    fun `requires three consecutive local API failures before recovery`() {
        var apiChecks = 0

        assertTrue(
            CoreLivenessMonitor.waitForUnexpectedExit(
                startToken = 7,
                currentGeneration = { 7 },
                isRunning = { true },
                isBridgeRunning = { true },
                isProtectMonitorRunning = { true },
                isApiHealthy = {
                    apiChecks++
                    false
                },
                sleep = {}
            )
        )
        assertEquals(3, apiChecks)
    }

    @Test
    fun `a healthy local API probe resets the consecutive failure count`() {
        val apiResults = ArrayDeque(listOf(false, false, true, false, false, false))

        assertTrue(
            CoreLivenessMonitor.waitForUnexpectedExit(
                startToken = 7,
                currentGeneration = { 7 },
                isRunning = { true },
                isBridgeRunning = { true },
                isProtectMonitorRunning = { true },
                isApiHealthy = { apiResults.removeFirst() },
                sleep = {}
            )
        )
        assertTrue(apiResults.isEmpty())
    }

    @Test
    fun `two local API failures do not recover after a normal disconnect`() {
        var running = true
        var sleeps = 0

        assertFalse(
            CoreLivenessMonitor.waitForUnexpectedExit(
                startToken = 7,
                currentGeneration = { 7 },
                isRunning = { running },
                isBridgeRunning = { true },
                isProtectMonitorRunning = { true },
                isApiHealthy = { false },
                sleep = {
                    sleeps++
                    if (sleeps == 2) running = false
                }
            )
        )
        assertEquals(2, sleeps)
    }

    @Test
    fun `healthy local pipeline does not recover for an unrelated external outage`() {
        var running = true
        var localApiChecks = 0

        assertFalse(
            CoreLivenessMonitor.waitForUnexpectedExit(
                startToken = 7,
                currentGeneration = { 7 },
                isRunning = { running },
                isBridgeRunning = { true },
                isProtectMonitorRunning = { true },
                isApiHealthy = {
                    localApiChecks++
                    true
                },
                sleep = {
                    if (localApiChecks == 3) running = false
                }
            )
        )
        assertEquals(3, localApiChecks)
    }
}
