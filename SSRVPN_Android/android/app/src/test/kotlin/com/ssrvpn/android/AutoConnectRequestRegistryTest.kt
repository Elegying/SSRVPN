package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoConnectRequestRegistryTest {
    @Test
    fun `persisted request survives registry recreation and is consumed once`() {
        val store = FakeCapabilityStore()
        val issuedId = AutoConnectRequestRegistry.issue(
            store,
            nowMillis = 1_000L,
            requestId = requestId(1)
        )

        assertEquals(requestId(1), issuedId)
        assertTrue(AutoConnectRequestRegistry.consume(store, issuedId, 1_001L))
        assertFalse(AutoConnectRequestRegistry.consume(store, issuedId, 1_002L))
        assertFalse(AutoConnectRequestRegistry.consume(store, null, 1_002L))
    }

    @Test
    fun `pending capabilities stay bounded`() {
        val store = FakeCapabilityStore()
        val requests = List(17) { index ->
            AutoConnectRequestRegistry.issue(
                store,
                nowMillis = 1_000L + index,
                requestId = requestId(index)
            )
        }

        assertEquals(16, store.entries.size)
        assertFalse(AutoConnectRequestRegistry.consume(store, requests.first(), 2_000L))
        assertTrue(AutoConnectRequestRegistry.consume(store, requests.last(), 2_000L))
    }

    @Test
    fun `expired and future-dated capabilities fail closed`() {
        val store = FakeCapabilityStore()
        val expired = requestId(20)
        val future = requestId(21)
        AutoConnectRequestRegistry.issue(store, 10_000L, expired)
        store.entries[future] = 10_001L + AutoConnectRequestRegistry.REQUEST_TTL_MS

        assertFalse(
            AutoConnectRequestRegistry.consume(
                store,
                expired,
                10_000L + AutoConnectRequestRegistry.REQUEST_TTL_MS
            )
        )
        assertFalse(AutoConnectRequestRegistry.consume(store, future, 10_001L))
        assertTrue(store.entries.isEmpty())
    }

    @Test
    fun `timestamp subtraction overflow cannot revive a future capability`() {
        val requestId = requestId(22)
        val store = FakeCapabilityStore(
            linkedMapOf(requestId to Long.MAX_VALUE)
        )

        assertFalse(AutoConnectRequestRegistry.consume(store, requestId, Long.MIN_VALUE))
        assertTrue(store.entries.isEmpty())
    }

    @Test
    fun `failed persistence never issues or consumes a capability`() {
        val store = FakeCapabilityStore(writesSucceed = false)
        val candidateId = requestId(30)

        assertNull(AutoConnectRequestRegistry.issue(store, 20_000L, candidateId))
        assertTrue(store.entries.isEmpty())

        store.writesSucceed = true
        assertEquals(candidateId, AutoConnectRequestRegistry.issue(store, 20_001L, candidateId))
        store.writesSucceed = false
        assertFalse(AutoConnectRequestRegistry.consume(store, candidateId, 20_002L))
        assertTrue(store.entries.containsKey(candidateId))

        store.writesSucceed = true
        assertTrue(AutoConnectRequestRegistry.consume(store, candidateId, 20_003L))
    }

    @Test
    fun `malformed request id cannot authorize auto connect`() {
        val store = FakeCapabilityStore(
            linkedMapOf("not-a-uuid" to 30_000L)
        )

        assertFalse(AutoConnectRequestRegistry.consume(store, "not-a-uuid", 30_001L))
        assertFalse(AutoConnectRequestRegistry.consume(store, "", 30_001L))
    }

    private fun requestId(index: Int): String =
        "00000000-0000-0000-0000-${index.toString().padStart(12, '0')}"

    private class FakeCapabilityStore(
        initial: Map<String, Long> = emptyMap(),
        var writesSucceed: Boolean = true
    ) : AutoConnectCapabilityStore {
        val entries = LinkedHashMap(initial)

        override fun read(): Map<String, Long> = entries.toMap()

        override fun replace(entries: Map<String, Long>): Boolean {
            if (!writesSucceed) return false
            this.entries.clear()
            this.entries.putAll(entries)
            return true
        }
    }
}
