package com.ssrvpn.android

import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreLivenessMonitorTest {
    @Test
    fun `stable native health makes the next recovery start at attempt one`() {
        var monotonicNow = 0L
        var bridgeChecks = 0

        val outcome = CoreLivenessMonitor.waitForUnexpectedExit(
            startToken = 7,
            currentGeneration = { 7 },
            isRunning = { true },
            recoveryAttempt = 2,
            isBridgeRunning = { ++bridgeChecks <= 2 },
            isProtectMonitorRunning = { true },
            isApiHealthy = { true },
            monotonicMillis = { monotonicNow },
            sleep = { monotonicNow = 120_000L }
        )

        assertTrue(outcome.unexpectedExit)
        assertEquals(0, outcome.recoveryAttempt)
        assertEquals(
            1,
            CoreRecoveryCoordinator.nextAttemptAfterUnexpectedExit(
                outcome.recoveryAttempt
            )
        )
    }

    @Test
    fun `reports unexpected exit while the same start is active`() {
        assertTrue(
            CoreLivenessMonitor.waitForUnexpectedExit(
                startToken = 7,
                currentGeneration = { 7 },
                isRunning = { true },
                isBridgeRunning = { false }
            ).unexpectedExit
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
            ).unexpectedExit
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
            ).unexpectedExit
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
            ).unexpectedExit
        )
    }

    @Test
    fun `requires three consecutive local API failures before port probe`() {
        var apiChecks = 0
        var portProbes = 0

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
                isApiPortReachable = {
                    portProbes++
                    false // 端口不可达 → 核心已死
                },
                apiFailureGraceMillis = 0,
                sleep = {}
            ).unexpectedExit
        )
        assertEquals(3, apiChecks)
        assertEquals(1, portProbes)
    }

    @Test
    fun `a zombie port still recovers once the grace window elapses`() {
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
                isApiPortReachable = { true }, // 僵尸端口仍可达
                apiFailureGraceMillis = 0,
                sleep = {}
            ).unexpectedExit
        )
        // 端口可达说明不是硬失败；但宽限已到期，同样应在达到阈值后重启
        assertEquals(3, apiChecks)
    }

    @Test
    fun `a healthy local API probe resets the consecutive failure count`() {
        // 失败×2 → 成功(重置) → 失败×3(端口可达且宽限为 0，达到阈值即重启)
        val apiResults = ArrayDeque(listOf(false, false, true, false, false, false))

        assertTrue(
            CoreLivenessMonitor.waitForUnexpectedExit(
                startToken = 7,
                currentGeneration = { 7 },
                isRunning = { true },
                isBridgeRunning = { true },
                isProtectMonitorRunning = { true },
                isApiHealthy = { apiResults.removeFirst() },
                isApiPortReachable = { true },
                apiFailureGraceMillis = 0,
                sleep = {}
            ).unexpectedExit
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
            ).unexpectedExit
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
            ).unexpectedExit
        )
        assertEquals(3, localApiChecks)
    }
    @Test
    fun `temporary API stall recovers without restarting the native session`() {
        var now = 0L
        var running = true
        var checks = 0
        val result = CoreLivenessMonitor.waitForUnexpectedExit(
            startToken = 7, currentGeneration = { 7 }, isRunning = { running },
            isBridgeRunning = { true },
            isApiHealthy = { ++checks >= 6 },
            // 端口仍可达 => 属于软失败，宽限未到就不得重启
            isApiPortReachable = { true },
            monotonicMillis = { now },
            sleep = { now += it; if (checks == 7) running = false }
        )
        assertFalse(result.unexpectedExit)
        assertEquals(7, checks)
    }

    @Test
    fun `persistent unresponsive API recovers after bounded grace`() {
        var now = 0L
        val result = CoreLivenessMonitor.waitForUnexpectedExit(
            startToken = 7, currentGeneration = { 7 }, isRunning = { true },
            isBridgeRunning = { true }, isApiHealthy = { false },
            isApiPortReachable = { true }, monotonicMillis = { now },
            sleep = { now += it }
        )
        assertTrue(result.unexpectedExit)
        assertEquals(15_000L, now)
    }

    @Test
    fun `suspend does not spend the remaining API grace window`() {
        var now = 0L
        var running = true
        var checks = 0
        val result = CoreLivenessMonitor.waitForUnexpectedExit(
            startToken = 7, currentGeneration = { 7 }, isRunning = { running },
            isBridgeRunning = { true }, isApiHealthy = { checks++; false },
            isApiPortReachable = { true },
            monotonicMillis = { now },
            sleep = {
                now += if (checks == 3) 120_000L else it
                if (checks == 6) running = false
            }
        )
        assertFalse(result.unexpectedExit)
    }

}
