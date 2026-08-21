package com.ssrvpn.android

import java.net.UnknownHostException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnDataPlaneProbeTest {
    @Test
    fun `accepts only a real generate 204 response`() {
        assertTrue(VpnDataPlaneProbe.isReachable(fetchStatus = { 204 }))
        assertFalse(VpnDataPlaneProbe.isReachable(fetchStatus = { 200 }))
        assertFalse(VpnDataPlaneProbe.isReachable(fetchStatus = { 302 }))
    }

    @Test
    fun `rotates independent endpoints and succeeds when a later path works`() {
        val attempted = mutableListOf<String>()

        val reachable = VpnDataPlaneProbe.isReachable(
            endpoints = listOf("first", "second"),
            maxAttempts = 3,
            fetchStatus = { endpoint ->
                attempted += endpoint
                if (attempted.size == 3) 204 else null
            }
        )

        assertTrue(reachable)
        assertEquals(listOf("first", "second", "first"), attempted)
    }

    @Test
    fun `fails closed after all bounded attempts`() {
        var attempts = 0

        val reachable = VpnDataPlaneProbe.isReachable(
            maxAttempts = 9,
            fetchStatus = {
                attempts++
                null
            }
        )

        assertFalse(reachable)
        assertEquals(3, attempts)
    }

    @Test
    fun `default attempts span independent providers`() {
        val attempted = mutableListOf<String>()

        VpnDataPlaneProbe.isReachable(fetchStatus = { endpoint ->
            attempted += endpoint
            null
        })

        assertEquals(
            listOf(
                "https://www.gstatic.com/generate_204",
                "https://www.youtube.com/generate_204",
                "https://cp.cloudflare.com/generate_204"
            ),
            attempted
        )
    }

    @Test
    fun `probe diagnostics expose only bounded endpoint and cause categories`() {
        val attempts = mutableListOf<VpnDataPlaneProbe.AttemptDiagnostic>()

        assertFalse(
            VpnDataPlaneProbe.isReachable(
                endpoints = listOf("https://private.example/path?token=secret"),
                maxAttempts = 1,
                fetchStatus = { throw UnknownHostException("private.example") },
                recordAttempt = attempts::add
            )
        )

        val diagnostic = attempts.single()
        assertEquals("other", diagnostic.endpointCategory)
        assertEquals(1, diagnostic.attempt)
        assertEquals(1, diagnostic.totalAttempts)
        assertEquals(null, diagnostic.status)
        assertEquals("dns", diagnostic.cause)
        assertTrue(diagnostic.elapsedMillis >= 0L)
        assertFalse(diagnostic.toString().contains("private.example"))
        assertFalse(diagnostic.toString().contains("secret"))
    }

    @Test
    fun `non-204 response is logged as an HTTP status without weakening the gate`() {
        val attempts = mutableListOf<VpnDataPlaneProbe.AttemptDiagnostic>()

        assertFalse(
            VpnDataPlaneProbe.isReachable(
                endpoints = listOf("https://www.gstatic.com/generate_204"),
                maxAttempts = 1,
                fetchStatus = { 200 },
                recordAttempt = attempts::add
            )
        )

        assertEquals("google", attempts.single().endpointCategory)
        assertEquals(200, attempts.single().status)
        assertEquals("http_status", attempts.single().cause)
    }

    @Test
    fun `hard budget fails closed when resolver ignores URL timeouts`() {
        val resolverStarted = CountDownLatch(1)
        val releaseResolver = CountDownLatch(1)
        val resolverFinished = CountDownLatch(1)
        val diagnosticPublished = CountDownLatch(1)
        val startedAt = System.nanoTime()

        val outcome = VpnDataPlaneProbe.probeReachability(
            endpoints = listOf("https://www.gstatic.com/generate_204"),
            maxAttempts = 1,
            totalBudgetMillis = 100L,
            fetchStatus = {
                resolverStarted.countDown()
                try {
                    releaseResolver.await()
                    204
                } finally {
                    resolverFinished.countDown()
                }
            },
            recordAttempt = { diagnosticPublished.countDown() }
        )
        val elapsedMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt)
        releaseResolver.countDown()

        assertTrue(resolverStarted.await(1, TimeUnit.SECONDS))
        assertEquals(VpnDataPlaneProbe.StartupOutcome.WATCHDOG_TIMEOUT, outcome)
        assertTrue("probe exceeded its hard budget: ${elapsedMillis}ms", elapsedMillis < 1_000L)
        assertTrue(resolverFinished.await(1, TimeUnit.SECONDS))
        assertFalse(diagnosticPublished.await(100, TimeUnit.MILLISECONDS))
    }

    @Test
    fun `timed out uninterruptible probe stays single flight until its worker exits`() {
        val firstFetchStarted = CountDownLatch(1)
        val releaseFirstFetch = CountDownLatch(1)
        val firstFetchFinished = CountDownLatch(1)

        val firstReachable = VpnDataPlaneProbe.isReachable(
            endpoints = listOf("https://www.gstatic.com/generate_204"),
            maxAttempts = 1,
            totalBudgetMillis = 50L,
            fetchStatus = {
                firstFetchStarted.countDown()
                try {
                    while (true) {
                        try {
                            if (releaseFirstFetch.await(10, TimeUnit.MILLISECONDS)) break
                        } catch (_: InterruptedException) {
                            // Deliberately ignore interruption like a stuck resolver can.
                        }
                    }
                    204
                } finally {
                    firstFetchFinished.countDown()
                }
            }
        )

        assertTrue(firstFetchStarted.await(1, TimeUnit.SECONDS))
        assertFalse(firstReachable)
        var overlappingFetches = 0
        assertEquals(
            VpnDataPlaneProbe.StartupOutcome.PREVIOUS_PROBE_STILL_RUNNING,
            VpnDataPlaneProbe.probeReachability(
                endpoints = listOf("https://www.gstatic.com/generate_204"),
                maxAttempts = 1,
                totalBudgetMillis = 50L,
                fetchStatus = {
                    overlappingFetches++
                    204
                }
            ),
        )
        assertEquals(0, overlappingFetches)

        releaseFirstFetch.countDown()
        assertTrue(firstFetchFinished.await(1, TimeUnit.SECONDS))
        val retryDeadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(1)
        var recovered = false
        while (!recovered && System.nanoTime() < retryDeadline) {
            recovered = VpnDataPlaneProbe.isReachable(
                endpoints = listOf("https://www.gstatic.com/generate_204"),
                maxAttempts = 1,
                totalBudgetMillis = 50L,
                fetchStatus = { 204 }
            )
            if (!recovered) Thread.yield()
        }
        assertTrue(recovered)
    }

    @Test
    fun `retry waits for a timed out worker then performs a fresh exact probe`() {
        val firstFetchStarted = CountDownLatch(1)
        val releaseFirstFetch = CountDownLatch(1)
        val retryFetchStarted = CountDownLatch(1)
        val retryResult = AtomicReference<Boolean>()

        try {
            assertFalse(
                VpnDataPlaneProbe.isReachable(
                    endpoints = listOf("https://www.gstatic.com/generate_204"),
                    maxAttempts = 1,
                    totalBudgetMillis = 50L,
                    fetchStatus = {
                        firstFetchStarted.countDown()
                        while (true) {
                            try {
                                if (releaseFirstFetch.await(10, TimeUnit.MILLISECONDS)) break
                            } catch (_: InterruptedException) {
                                // Deliberately model a resolver that ignores interruption.
                            }
                        }
                        204
                    }
                )
            )
            assertTrue(firstFetchStarted.await(1, TimeUnit.SECONDS))

            val retryThread = Thread {
                retryResult.set(
                    VpnDataPlaneProbe.isReachable(
                        endpoints = listOf("https://www.gstatic.com/generate_204"),
                        maxAttempts = 1,
                        totalBudgetMillis = 500L,
                        fetchStatus = {
                            retryFetchStarted.countDown()
                            204
                        }
                    )
                )
            }
            retryThread.start()

            assertFalse(retryFetchStarted.await(50, TimeUnit.MILLISECONDS))
            releaseFirstFetch.countDown()
            assertTrue(retryFetchStarted.await(1, TimeUnit.SECONDS))
            retryThread.join(1_000L)
            assertFalse(retryThread.isAlive)
            assertEquals(true, retryResult.get())
        } finally {
            releaseFirstFetch.countDown()
        }
    }

    @Test
    fun `busy and watchdog outcomes have distinct actionable messages`() {
        assertEquals(
            "上次 VPN 联网检查仍在结束，请稍后重试；若持续出现请重启应用",
            VpnDataPlaneProbe.StartupOutcome.PREVIOUS_PROBE_STILL_RUNNING.failureMessage
        )
        assertEquals(
            "VPN 联网检查超时，请稍后重试；若持续出现请重启应用",
            VpnDataPlaneProbe.StartupOutcome.WATCHDOG_TIMEOUT.failureMessage
        )
    }

    @Test
    fun `activity timeout covers every legal native startup stage`() {
        val requiredBudget =
            VpnStartBudget.BRIDGE_MS +
                VpnStartBudget.API_HEALTH_MS +
                VpnStartBudget.PROXY_SELECTION_MS +
                VpnDataPlaneProbe.MAX_STARTUP_DURATION_MILLIS

        assertTrue(VpnStartBudget.RESULT_MS > requiredBudget)
    }

    @Test
    fun `tile callback timeout covers the native startup result budget`() {
        assertTrue(
            VpnTileService.START_CALLBACK_TIMEOUT_MS >=
                VpnStartBudget.RESULT_MS
        )
    }
}
