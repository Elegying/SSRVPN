package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class VpnServiceStopGateTest {
    @Test
    fun `rejected start during cleanup remains covered by the pending stop`() {
        val gate = VpnServiceStopGate()
        gate.acceptStart(10)
        val stop = gate.beginOrJoinStop()

        gate.includeRejectedStart(11)

        assertEquals(11, gate.finishStop(stop))
    }

    @Test
    fun `accepted later start invalidates the stale stop completion`() {
        val gate = VpnServiceStopGate()
        gate.acceptStart(10)
        val staleStop = gate.beginOrJoinStop()

        gate.acceptStart(11)

        assertNull(gate.finishStop(staleStop))
    }
}
