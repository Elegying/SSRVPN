package com.ssrvpn.android

import org.junit.Assert.*
import org.junit.Test

class RetainedUiSessionTest {
    @Test fun `destroyed windows reuse the running runtime and its verification state`() {
        val session = RetainedUiSession<MutableMap<String, Any>, Any>()
        var created = 0
        fun acquire() = session.acquire { created++; mutableMapOf("verified" to false) }
        val original = acquire()
        val first = Any()
        session.attach(first)
        original["verified"] = true
        repeat(20) {
            assertTrue(session.detach(session.currentHost()!!))
            assertNull(session.currentHost())
            assertSame(original, acquire())
            session.attach(Any())
        }
        assertEquals(1, created)
        assertEquals(true, acquire()["verified"])
    }

    @Test fun `late old-window destruction cannot clear the new host`() {
        val session = RetainedUiSession<Any, Any>()
        val old = Any()
        val current = Any()
        session.attach(old)
        session.attach(current)
        assertFalse(session.detach(old))
        assertSame(current, session.currentHost())
        assertTrue(session.detach(current))
        assertFalse(session.detach(current))
        assertNull(session.currentHost())
    }

    @Test fun `failed construction can retry without retaining a partial runtime`() {
        val session = RetainedUiSession<Any, Any>()
        assertThrows(IllegalStateException::class.java) {
            session.acquire { throw IllegalStateException("unavailable") }
        }
        val successful = Any()
        assertSame(successful, session.acquire { successful })
        assertSame(successful, session.acquire { error("must not initialize twice") })
    }

    @Test fun `a new process cannot inherit a previous connection result`() {
        val previous = RetainedUiSession<Any, Any>()
        val replacement = RetainedUiSession<Any, Any>()
        assertNotSame(previous.acquire { Any() }, replacement.acquire { Any() })
        assertNull(replacement.currentHost())
    }

    @Test fun `trusted launch survives a window gap and is consumed only once`() {
        val session = RetainedUiSession<Any, Any>()
        val first = Any()
        val next = Any()
        session.attach(first)
        session.enqueueAction()
        session.detach(first)
        assertFalse(session.consumeAction())
        assertTrue(session.hasPendingAction)
        session.attach(next)
        assertTrue(session.consumeAction())
        assertFalse(session.consumeAction())
        assertFalse(RetainedUiSession<Any, Any>().hasPendingAction)
    }
}
