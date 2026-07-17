package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MihomoApiWaiterTest {
    @Test
    fun `health polling stops at the first successful probe`() {
        var probes = 0
        var generationChecks = 0
        val waiter = MihomoApiWaiter { _, _, _ ->
            probes += 1
            probes >= 2
        }

        val healthy = waiter.waitUntilHealthy(
            apiPort = 9090,
            apiSecret = "secret",
            deadlineNanos = System.nanoTime() + 1_000_000_000L,
            pollIntervalMillis = 1L,
            ensureCurrent = { generationChecks += 1 }
        )

        assertTrue(healthy)
        assertEquals(2, probes)
        assertTrue(generationChecks >= probes * 2)
    }
}
