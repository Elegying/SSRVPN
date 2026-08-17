package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeRuntimeDiagnosticsTest {
    private val tracker = NativeRuntimeDiagnosticsTracker()

    @Test
    fun `diagnostic snapshot exposes state only and no protected values`() {
        val snapshot = NativeRuntimeDiagnostics(
            serviceRunning = true,
            operationBusy = false,
            tunEstablished = true,
            bridgeReady = true,
            protectMonitorAlive = true
        ).toMap()

        assertTrue(snapshot["serviceRunning"] as Boolean)
        assertTrue(snapshot["tunEstablished"] as Boolean)
        assertTrue(snapshot["bridgeReady"] as Boolean)
        assertTrue(snapshot["protectMonitorAlive"] as Boolean)
        assertFalse(snapshot.containsKey("apiSecret"))
        assertFalse(snapshot.containsKey("config"))
        assertEquals(1, snapshot["schemaVersion"])
    }

    @Test
    fun `TUN interface evidence stays independent from a failed Bridge probe`() {
        tracker.claimTunDescriptor(42) { setOf("tun0") }

        val snapshot = tracker.snapshot(
            serviceRunning = true,
            operationBusy = false,
            protectMonitorAlive = true,
            bridgeReady = false,
            activeTunInterfaces = { setOf("tun0") }
        ).toMap()

        assertTrue(snapshot["tunEstablished"] as Boolean)
        assertFalse(snapshot["bridgeReady"] as Boolean)
    }

    @Test
    fun `TUN ownership requires the exact interface captured by the claim`() {
        tracker.beginTunLease { setOf("tun0") }
        tracker.claimTunDescriptor(42) { setOf("tun0", "tun1") }

        val matchingSnapshot = tracker.snapshot(
            serviceRunning = true,
            operationBusy = false,
            protectMonitorAlive = true,
            bridgeReady = true,
            activeTunInterfaces = { setOf("tun1") }
        ).toMap()
        assertTrue(matchingSnapshot["tunEstablished"] as Boolean)

        val unrelatedTunSnapshot = tracker.snapshot(
            serviceRunning = true,
            operationBusy = false,
            protectMonitorAlive = true,
            bridgeReady = true,
            activeTunInterfaces = { setOf("tun0") }
        ).toMap()
        assertFalse(unrelatedTunSnapshot["tunEstablished"] as Boolean)

        assertTrue(
            tracker.releaseTunDescriptorIfClosed(
                tunInterfaces = { emptySet() },
                descriptorTarget = { null }
            )
        )
        val releasedSnapshot = tracker.snapshot(
            serviceRunning = true,
            operationBusy = false,
            protectMonitorAlive = true,
            bridgeReady = true,
            activeTunInterfaces = { setOf("tun0") }
        ).toMap()
        assertFalse(releasedSnapshot["tunEstablished"] as Boolean)
    }

    @Test
    fun `release proof keeps the lease until both descriptor and interface disappear`() {
        tracker.beginTunLease { emptySet() }
        tracker.claimTunDescriptor(42) { setOf("tun0") }

        assertFalse(
            tracker.releaseTunDescriptorIfClosed(
                tunInterfaces = { setOf("tun0") },
                descriptorTarget = { "/dev/tun" }
            )
        )
        assertFalse(
            tracker.releaseTunDescriptorIfClosed(
                tunInterfaces = { emptySet() },
                descriptorTarget = { "/dev/tun" }
            )
        )
        assertTrue(
            tracker.releaseTunDescriptorIfClosed(
                tunInterfaces = { emptySet() },
                descriptorTarget = { null }
            )
        )
    }

    @Test
    fun `residual TUN and Bridge remain visible after service flag drops`() {
        tracker.claimTunDescriptor(42) { setOf("tun0") }

        val snapshot = tracker.snapshot(
            serviceRunning = false,
            operationBusy = true,
            protectMonitorAlive = false,
            bridgeReady = true,
            activeTunInterfaces = { setOf("tun0") }
        ).toMap()

        assertTrue(snapshot["tunEstablished"] as Boolean)
        assertTrue(snapshot["bridgeReady"] as Boolean)
    }

    @Test
    fun `failed interface enumeration reports unknown instead of healthy`() {
        tracker.claimTunDescriptor(42) { null }

        val snapshot = tracker.snapshot(
            serviceRunning = true,
            operationBusy = false,
            protectMonitorAlive = true,
            bridgeReady = true,
            activeTunInterfaces = { null }
        ).toMap()

        assertEquals(null, snapshot["tunEstablished"])
    }
}
