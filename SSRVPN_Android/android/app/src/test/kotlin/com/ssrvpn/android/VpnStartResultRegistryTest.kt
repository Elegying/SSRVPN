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

    @Test
    fun `native failure code reaches the registered client unchanged`() {
        var capturedCode: String? = null
        val requestId = VpnStartResultRegistry.register { _, _, state ->
            capturedCode =
                state?.get(NativeCoreStartFailureCategory.FAILURE_CODE_KEY) as? String
        }

        VpnStartResultRegistry.consume(
            requestId,
            false,
            "VPN 核心启动失败",
            NativeCoreStartFailureCategory.PORT_CONFLICT.methodChannelFailureState
        )

        assertEquals("CORE_START_PORT_CONFLICT", capturedCode)
    }
}
