package com.ssrvpn.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationGenerationGateTest {
    @Test
    fun `queued notification is invalid after stop`() {
        val gate = NotificationGenerationGate()
        val queued = gate.capture()

        gate.invalidate()

        assertFalse(gate.isCurrent(queued))
        assertTrue(gate.isCurrent(gate.capture()))
    }
}
