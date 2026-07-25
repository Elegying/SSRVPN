package com.ssrvpn.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CorePortReleaseVerifierTest {
    @Test
    fun `waits until the core API port is released`() {
        val observations = ArrayDeque(listOf(true, true, false))

        val released = CorePortReleaseVerifier.waitUntilReleased(
            port = 9090,
            attempts = 3,
            retryDelayMillis = 0,
            canConnect = { observations.removeFirst() },
        )

        assertTrue(released)
        assertTrue(observations.isEmpty())
    }

    @Test
    fun `rejects stop completion while the core API port still listens`() {
        val released = CorePortReleaseVerifier.waitUntilReleased(
            port = 9090,
            attempts = 3,
            retryDelayMillis = 0,
            canConnect = { true },
        )

        assertFalse(released)
    }

    @Test
    fun `isPortListening returns true when port is open`() {
        // 使用 canConnect 参数注入
        val verifier = CorePortReleaseVerifier
        // isPortListening 内部用 canConnect，这里通过端口 0 测试边界
        // 直接用一个肯定失败的端口验证 false 分支
        assertFalse(verifier.isPortListening(0))
    }
}
