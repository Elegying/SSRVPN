package com.ssrvpn.android

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
}
