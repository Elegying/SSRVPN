package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnStartupPolicyTest {
    @Test
    fun `missing config takes precedence over an absent API secret`() {
        val failure = nativeCoreStartInputFailure(null, null, "")

        assertEquals(NativeCoreStartFailureCategory.CONFIG, failure?.category)
        assertEquals("VPN 配置不可用，请打开应用重新连接", failure?.message)
    }

    @Test
    fun `an absent API secret is classified after config paths are present`() {
        val failure = nativeCoreStartInputFailure("/data/runtime", "/data/runtime/config.yaml", "")

        assertEquals(NativeCoreStartFailureCategory.API_AUTH, failure?.category)
        assertEquals("VPN 凭据不可用，请打开应用重新连接", failure?.message)
    }

    @Test
    fun `complete native startup inputs do not invent a failure`() {
        assertEquals(
            null,
            nativeCoreStartInputFailure(
                "/data/runtime",
                "/data/runtime/config.yaml",
                "secret"
            )
        )
    }

    @Test
    fun `activity timeout covers only native startup stages`() {
        val requiredBudget =
            VpnStartBudget.BRIDGE_MS +
                VpnStartBudget.API_HEALTH_MS +
                VpnStartBudget.PROXY_SELECTION_MS

        assertEquals(requiredBudget + 5_000L, VpnStartBudget.RESULT_MS)
    }

    @Test
    fun `tile callback timeout covers the native startup result budget`() {
        assertTrue(
            VpnTileService.START_CALLBACK_TIMEOUT_MS >=
                VpnStartBudget.RESULT_MS
        )
    }

    @Test
    fun `native core failure logs use bounded categories`() {
        val cases = mapOf(
            "permission denied at /data/user/0/private/config.yaml" to "permission",
            "address already in use: token=secret" to "port_conflict",
            "controller returned unauthorized" to "api_auth",
            "failed to create tun device" to "tun",
            "protect monitor is unavailable" to "tun",
            "invalid config password=secret" to "config",
            "operation timed out for /data/user/0/private" to "timeout",
            "panic at /data/user/0/private token=secret" to "unknown"
        )

        for ((raw, expected) in cases) {
            val category = NativeCoreStartFailureCategory.from(raw).logValue
            assertEquals(expected, category)
            assertFalse(category.contains("private"))
            assertFalse(category.contains("secret"))
            assertTrue(category.length <= 16)
        }
    }

    @Test
    fun `bare bind text is not treated as a port conflict`() {
        assertEquals(
            NativeCoreStartFailureCategory.TUN,
            NativeCoreStartFailureCategory.from("failed to bind TUN interface")
        )
        assertEquals(
            NativeCoreStartFailureCategory.UNKNOWN,
            NativeCoreStartFailureCategory.from("failed to bind upstream socket")
        )
        assertEquals(
            NativeCoreStartFailureCategory.PORT_CONFLICT,
            NativeCoreStartFailureCategory.from("listen tcp: bind: address already in use")
        )
        assertEquals(
            NativeCoreStartFailureCategory.PORT_CONFLICT,
            NativeCoreStartFailureCategory.from(java.net.BindException("bind failed"))
        )
        assertEquals(
            NativeCoreStartFailureCategory.TIMEOUT,
            NativeCoreStartFailureCategory.from(
                java.util.concurrent.TimeoutException("config validation timed out")
            )
        )
    }

    @Test
    fun `API readiness failures have stable user-facing categories`() {
        val portConflict = MihomoApiReadiness.PORT_CONFLICT.startupFailure()
        assertEquals(NativeCoreStartFailureCategory.PORT_CONFLICT, portConflict.category)
        assertTrue(portConflict.message.contains("端口"))
        assertTrue(portConflict.message.contains("自动更换"))

        val authRejected = MihomoApiReadiness.AUTH_REJECTED.startupFailure()
        assertEquals(NativeCoreStartFailureCategory.API_AUTH, authRejected.category)
        assertTrue(authRejected.message.contains("凭据"))
        assertFalse(authRejected.message.contains("端口"))

        val tunDisabled = MihomoApiReadiness.TUN_DISABLED.startupFailure()
        assertEquals(NativeCoreStartFailureCategory.TUN, tunDisabled.category)
        assertTrue(tunDisabled.message.contains("TUN"))

        val timeout = MihomoApiReadiness.TIMEOUT.startupFailure()
        assertEquals(NativeCoreStartFailureCategory.TIMEOUT, timeout.category)
        assertTrue(timeout.message.contains("未及时就绪"))
    }

    @Test
    fun `native core failure categories expose stable method channel codes`() {
        assertEquals(
            "CORE_START_PORT_CONFLICT",
            NativeCoreStartFailureCategory.PORT_CONFLICT.methodChannelCode
        )
        assertEquals(
            "CORE_START_API_AUTH",
            NativeCoreStartFailureCategory.API_AUTH.methodChannelCode
        )
        assertEquals(
            "CORE_START_TIMEOUT",
            NativeCoreStartFailureCategory.TIMEOUT.methodChannelCode
        )
        assertEquals(
            "CORE_START_UNKNOWN",
            NativeCoreStartFailureCategory.UNKNOWN.methodChannelCode
        )
        assertEquals(
            "CORE_START_COMPONENT",
            NativeCoreStartFailureCategory.COMPONENT.methodChannelCode
        )
        assertEquals(
            "CORE_START_BUSY",
            NativeCoreStartFailureCategory.BUSY.methodChannelCode
        )
    }

    @Test
    fun `missing native failure state falls back to the stable unknown code`() {
        assertEquals(
            "CORE_START_UNKNOWN",
            NativeCoreStartFailureCategory.methodChannelCodeFromState(null)
        )
        assertEquals(
            "CORE_START_UNKNOWN",
            NativeCoreStartFailureCategory.methodChannelCodeFromState(emptyMap())
        )
        assertEquals(
            "CORE_START_UNKNOWN",
            NativeCoreStartFailureCategory.methodChannelCodeFromState(
                mapOf(NativeCoreStartFailureCategory.FAILURE_CODE_KEY to "CORE_START_FUTURE")
            )
        )
        assertEquals(
            "CORE_START_TUN",
            NativeCoreStartFailureCategory.methodChannelCodeFromState(
                NativeCoreStartFailureCategory.TUN.methodChannelFailureState
            )
        )
        assertEquals(
            "CORE_START_COMPONENT",
            NativeCoreStartFailureCategory.methodChannelCodeFromState(
                NativeCoreStartFailureCategory.COMPONENT.methodChannelFailureState
            )
        )
        assertEquals(
            "CORE_START_BUSY",
            NativeCoreStartFailureCategory.methodChannelCodeFromState(
                NativeCoreStartFailureCategory.BUSY.methodChannelFailureState
            )
        )
    }

    @Test
    fun `native throwable categories do not expose paths or secrets`() {
        val raw = IllegalStateException(
            "startup failed at /data/user/0/com.ssrvpn/files/config.yaml token=secret",
            SecurityException("permission denied password=secret")
        )

        val category = NativeCoreStartFailureCategory.from(raw).logValue

        assertEquals("permission", category)
        assertFalse(category.contains("/data/user"))
        assertFalse(category.contains("secret"))
        assertTrue(category.length <= 16)
    }
}
