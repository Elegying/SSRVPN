package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Test

class VpnStartResultRegistryTest {
    @Test
    fun `consumer callback failure is contained and removed`() {
        var invocations = 0
        val requestId = VpnStartResultRegistry.register { _, _, _ ->
            invocations += 1
            throw IllegalStateException("detached client callback")
        }

        VpnStartResultRegistry.consume(requestId, true, "OK")
        VpnStartResultRegistry.consume(requestId, true, "duplicate")

        assertEquals(1, invocations)
    }
}
