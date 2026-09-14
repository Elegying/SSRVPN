package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Test

class MihomoApiWaiterTest {
    @Test
    fun `missing rules wait for loading then retain a distinct failure category`() {
        val waiter = MihomoApiWaiter { _, _, _ -> MihomoApiReadiness.RULES_PENDING }
        val result = waiter.waitUntilReady(9090, "secret",
            System.nanoTime() + 5_000_000L, 1L, {})
        assertEquals(MihomoApiReadiness.RULES_PENDING, result)
        assertEquals(NativeCoreStartFailureCategory.RULES, result.startupFailure().category)
    }

    @Test
    fun `rule loading can settle without a fallback`() {
        var probes = 0
        val waiter = MihomoApiWaiter { _, _, _ ->
            if (++probes == 1) MihomoApiReadiness.RULES_PENDING else MihomoApiReadiness.READY
        }
        assertEquals(MihomoApiReadiness.READY, waiter.waitUntilReady(9090, "secret",
            System.nanoTime() + 1_000_000_000L, 1L, {}))
    }

    @Test
    fun `readiness polling stops at the first ready probe`() {
        var probes = 0
        var generationChecks = 0
        val waiter = MihomoApiWaiter { _, _, _ ->
            probes += 1
            if (probes >= 2) MihomoApiReadiness.READY else MihomoApiReadiness.PENDING
        }

        val readiness = waiter.waitUntilReady(
            apiPort = 9090,
            apiSecret = "secret",
            deadlineNanos = System.nanoTime() + 1_000_000_000L,
            pollIntervalMillis = 1L,
            ensureCurrent = { generationChecks += 1 }
        )

        assertEquals(MihomoApiReadiness.READY, readiness)
        assertEquals(2, probes)
        assertEquals(4, generationChecks)
    }

    @Test
    fun `terminal startup failures are not retried`() {
        for (failure in listOf(
            MihomoApiReadiness.PORT_CONFLICT,
            MihomoApiReadiness.AUTH_REJECTED,
            MihomoApiReadiness.TUN_DISABLED,
            MihomoApiReadiness.TIMEOUT
        )) {
            var probes = 0
            val waiter = MihomoApiWaiter { _, _, _ ->
                probes += 1
                failure
            }

            val readiness = waiter.waitUntilReady(
                apiPort = 9090,
                apiSecret = "secret",
                deadlineNanos = System.nanoTime() + 1_000_000_000L,
                pollIntervalMillis = 1L,
                ensureCurrent = {}
            )

            assertEquals(failure, readiness)
            assertEquals(1, probes)
        }
    }

    @Test
    fun `pending readiness expires as a timeout`() {
        val waiter = MihomoApiWaiter { _, _, _ -> MihomoApiReadiness.PENDING }

        val readiness = waiter.waitUntilReady(
            apiPort = 9090,
            apiSecret = "secret",
            deadlineNanos = System.nanoTime() + 5_000_000L,
            pollIntervalMillis = 1L,
            ensureCurrent = {}
        )

        assertEquals(MihomoApiReadiness.TIMEOUT, readiness)
    }
}
