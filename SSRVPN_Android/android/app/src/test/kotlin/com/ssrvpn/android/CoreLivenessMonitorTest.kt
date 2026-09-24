package com.ssrvpn.android

import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreLivenessMonitorTest {
    @Test
    fun `late monitor exit and failure cannot stop a replacement session`() {
        for (failObservation in listOf(false, true)) {
            val gate = StartGenerationGate()
            val oldToken = gate.beginStart()
            var activeConfig = "old-config"
            var connected = true
            var recoveryAttempts = 0
            var failureNotices = 0

            CoreLivenessMonitor.observeSession(
                startToken = oldToken,
                gate = gate,
                waitForExit = {
                    val outcome = CoreLivenessMonitor.waitForUnexpectedExit(
                        startToken = oldToken,
                        currentGeneration = gate::current,
                        isRunning = { connected },
                        isBridgeRunning = { false }
                    )
                    assertTrue(outcome.unexpectedExit)
                    // The old worker is suspended after its final observation.
                    // Disconnect and connect finish before that worker resumes.
                    gate.invalidate { connected = false }
                    gate.beginStart {
                        activeConfig = "replacement-config"
                        connected = true
                    }
                    if (failObservation) throw IllegalStateException("late monitor failure")
                    outcome
                },
                onUnexpectedExit = {
                    connected = false
                    activeConfig = "old-config"
                    recoveryAttempts++
                },
                onFailure = {
                    connected = false
                    failureNotices++
                }
            )

            assertTrue("replacement connection must remain active", connected)
            assertEquals("replacement-config", activeConfig)
            assertEquals(0, recoveryAttempts)
            assertEquals(0, failureNotices)
        }
    }

    @Test
    fun `current monitor exit and failure retain recovery behavior`() {
        for (failObservation in listOf(false, true)) {
            val gate = StartGenerationGate()
            val token = gate.beginStart()
            var connected = true
            var recoveryAttempts = 0
            var failureNotices = 0

            CoreLivenessMonitor.observeSession(
                startToken = token,
                gate = gate,
                waitForExit = {
                    if (failObservation) throw IllegalStateException("current monitor failure")
                    CoreLivenessOutcome(true, 1)
                },
                onUnexpectedExit = {
                    connected = false
                    recoveryAttempts = it.recoveryAttempt + 1
                    gate.invalidate()
                },
                onFailure = {
                    connected = false
                    failureNotices++
                    gate.invalidate()
                }
            )

            assertFalse(connected)
            assertEquals(if (failObservation) 0 else 2, recoveryAttempts)
            assertEquals(if (failObservation) 1 else 0, failureNotices)
        }
    }

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
        // 3 次失败后触发第一次端口探测；单次不可达不算硬证据，第 4 次轮询
        // 再次不可达才累计到 PORT_MISSES_BEFORE_RESTART，随即重启。
        assertEquals(4, apiChecks)
        assertEquals(2, portProbes)
    }

    @Test
    fun `a single unreachable port probe does not restart the core`() {
        val now = 0L
        var portProbes = 0

        // 端口探测本身只是一次 100 ms 采样，单次失败可能只是调度抖动导致的
        // 伪超时。这里让它第一次不可达、第二次恢复可达：因为凑不满
        // PORT_MISSES_BEFORE_RESTART 次连续失败，核心不得被判定为死亡。
        // 循环在第二次探测后由 isRunning 收尾（isRunning 恒为 true 会让循环
        // 无法终止，而 60s 宽限在 sleep 为空时不推进时钟，永远到不了）。
        val outcome = CoreLivenessMonitor.waitForUnexpectedExit(
            startToken = 7,
            currentGeneration = { 7 },
            isRunning = { portProbes < 2 },
            isBridgeRunning = { true },
            isProtectMonitorRunning = { true },
            isApiHealthy = { false },
            isApiPortReachable = {
                portProbes++
                portProbes != 1 // 第一次不可达，之后可达
            },
            apiFailureGraceMillis = 60_000L, // 大到不会因宽限而重启
            monotonicMillis = { now },
            sleep = {}
        )

        assertFalse(outcome.unexpectedExit)
        assertEquals(2, portProbes)
    }

    @Test
    fun `a reachable port restarts at the threshold once the grace window has expired`() {
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
        // apiFailureGraceMillis = 0 时 `now - firstApiFailure >= 0` 恒真，因此
        // 本用例并不检验宽限时长，只断言：端口可达（软失败）时，达到
        // MAX_CONSECUTIVE_API_FAILURES 即重启。真实宽限由下面
        // `persistent unresponsive API recovers after bounded grace` 守卫。
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
