package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NativeStartPayloadRegistryTest {
    @Test
    fun `runtime payload is addressed by an opaque one-time identifier`() {
        val snapshot = NativeConnectionSnapshot(
            configDir = "/private/runtime",
            configPath = "/private/runtime/config.yaml",
            apiPort = 9090,
            apiSecret = "secret-not-for-intent",
            selectedNodeName = "Node A"
        )

        val id = NativeStartPayloadRegistry.register(snapshot)

        assertNotEquals(snapshot.configPath, id)
        assertNotEquals(snapshot.apiSecret, id)
        assertEquals(snapshot, NativeStartPayloadRegistry.peek(id))
        assertEquals(snapshot, NativeStartPayloadRegistry.consume(id))
        assertNull(NativeStartPayloadRegistry.peek(id))
        assertNull(NativeStartPayloadRegistry.consume(id))
    }
}
