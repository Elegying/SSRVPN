package com.ssrvpn.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket

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
        val server = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        val port = server.localPort

        try {
            assertTrue(CorePortReleaseVerifier.isPortListening(port))
        } finally {
            server.close()
        }

        assertFalse(CorePortReleaseVerifier.isPortListening(port))
    }
}
