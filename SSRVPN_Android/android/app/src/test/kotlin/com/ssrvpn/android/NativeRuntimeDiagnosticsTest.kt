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
                descriptorTarget = { "/dev/tun" },
                descriptorInterface = {
                    TunDescriptorInterface(readable = true, name = "tun0")
                }
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
    fun `delayed TUN discovery does not outlive a closed descriptor`() {
        tracker.beginTunLease { emptySet() }
        tracker.claimTunDescriptor(42) { emptySet() }

        val connected = tracker.snapshot(
            serviceRunning = true,
            operationBusy = false,
            protectMonitorAlive = true,
            bridgeReady = true,
            activeTunInterfaces = { setOf("tun0") }
        ).toMap()

        assertTrue(connected["tunEstablished"] as Boolean)
        assertTrue(
            tracker.releaseTunDescriptorIfClosed(
                tunInterfaces = { setOf("tun0") },
                descriptorTarget = { null }
            )
        )
    }

    @Test
    fun `unobserved TUN generation releases after baseline and fd recover`() {
        tracker.beginTunLease { emptySet() }
        tracker.claimTunDescriptor(42) { emptySet() }

        assertTrue(
            tracker.releaseTunDescriptorIfClosed(
                tunInterfaces = { emptySet() },
                descriptorTarget = { null }
            )
        )
    }

    @Test
    fun `inactive lingering TUN releases after fd closes`() {
        tracker.beginTunLease { emptySet() }
        tracker.claimTunDescriptor(42) { setOf("tun0") }

        assertTrue(
            tracker.releaseTunDescriptorIfClosed(
                tunInterfaces = { emptySet() },
                descriptorTarget = { null }
            )
        )
    }

    @Test
    fun `Android retained interface releases after owned fd closes`() {
        tracker.beginTunLease { emptySet() }
        tracker.claimTunDescriptor(42) { setOf("tun0") }

        assertTrue(
            tracker.releaseTunDescriptorIfClosed(
                tunInterfaces = { setOf("tun0") },
                descriptorTarget = { null }
            )
        )
    }

    @Test
    fun `Android retained interface releases after fd is reused outside TUN`() {
        tracker.beginTunLease { emptySet() }
        tracker.claimTunDescriptor(42) { setOf("tun0") }

        assertTrue(
            tracker.releaseTunDescriptorIfClosed(
                tunInterfaces = { setOf("tun0") },
                descriptorTarget = { "socket:[1234]" }
            )
        )
    }

    @Test
    fun `unbound reused TUN descriptor does not retain the old lease`() {
        tracker.beginTunLease { emptySet() }
        tracker.claimTunDescriptor(42) { setOf("tun0") }

        assertTrue(
            tracker.releaseTunDescriptorIfClosed(
                tunInterfaces = { emptySet() },
                descriptorTarget = { "/dev/tun" },
                descriptorInterface = {
                    TunDescriptorInterface(readable = true, name = null)
                }
            )
        )
    }

    @Test
    fun `descriptor still attached to the owned TUN remains fail closed`() {
        tracker.beginTunLease { emptySet() }
        tracker.claimTunDescriptor(42) { setOf("tun0") }

        assertFalse(
            tracker.releaseTunDescriptorIfClosed(
                tunInterfaces = { emptySet() },
                descriptorTarget = { "/dev/tun" },
                descriptorInterface = {
                    TunDescriptorInterface(readable = true, name = "tun0")
                }
            )
        )
    }

    @Test
    fun `descriptor reused by a baseline TUN does not retain the owned lease`() {
        tracker.beginTunLease { setOf("tun0") }
        tracker.claimTunDescriptor(42) { setOf("tun0", "tun1") }

        assertTrue(
            tracker.releaseTunDescriptorIfClosed(
                tunInterfaces = { setOf("tun0") },
                descriptorTarget = { "/dev/tun" },
                descriptorInterface = {
                    TunDescriptorInterface(readable = true, name = "tun0")
                }
            )
        )
    }

    @Test
    fun `unreadable descriptor interface remains fail closed`() {
        tracker.beginTunLease { emptySet() }
        tracker.claimTunDescriptor(42) { setOf("tun0") }

        assertFalse(
            tracker.releaseTunDescriptorIfClosed(
                tunInterfaces = { emptySet() },
                descriptorTarget = { "/dev/tun" },
                descriptorInterface = {
                    TunDescriptorInterface(readable = false, name = null)
                }
            )
        )
    }

    @Test
    fun `unknown TUN baseline remains fail closed after fd release`() {
        tracker.beginTunLease { null }
        tracker.claimTunDescriptor(42) { null }

        assertFalse(
            tracker.releaseTunDescriptorIfClosed(
                tunInterfaces = { emptySet() },
                descriptorTarget = { null }
            )
        )
    }

    @Test
    fun `stop closes the retained VPN lease before checking kernel release`() {
        val events = mutableListOf<String>()
        var leaseOpen = true

        val released = TunReleaseVerifier.releaseOwnedLeaseAndWait(
            bridgeStopped = true,
            attempts = 1,
            retryDelayMillis = 0,
            closeOwnedLease = {
                events += "close"
                leaseOpen = false
            },
            isReleased = {
                events += "verify"
                !leaseOpen
            }
        )

        assertTrue(released)
        assertEquals(listOf("close", "verify"), events)
    }

    @Test
    fun `default release grace covers delayed Android 11 TUN teardown`() {
        var probes = 0

        val released = TunReleaseVerifier.waitUntilReleased(
            retryDelayMillis = 0
        ) {
            probes += 1
            probes == 101
        }

        assertTrue(released)
        assertEquals(101, probes)
    }

    @Test
    fun `failed bridge stop still closes the retained VPN lease`() {
        var closeCount = 0
        var verifierCalled = false

        val released = TunReleaseVerifier.releaseOwnedLeaseAndWait(
            bridgeStopped = false,
            attempts = 1,
            retryDelayMillis = 0,
            closeOwnedLease = { closeCount += 1 },
            isReleased = {
                verifierCalled = true
                true
            }
        )

        assertFalse(released)
        assertEquals(1, closeCount)
        assertFalse(verifierCalled)
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
