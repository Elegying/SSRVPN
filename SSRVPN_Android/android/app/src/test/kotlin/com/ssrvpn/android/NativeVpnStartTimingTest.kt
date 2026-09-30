package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Test

class NativeVpnStartTimingTest {
    @Test
    fun `permission interaction never counts as service startup time`() {
        var now = 0L
        val timing = NativeVpnStartTiming { now }
        now = 10_000_000L
        timing.beginPermissionWait()
        now = 6_010_000_000L
        timing.endPermissionWait()
        now = 6_020_000_000L
        timing.beginServiceStart()
        now = 6_070_000_000L
        assertEquals(mapOf(
            "authorizationRequested" to true,
            "authorizationWaitMs" to 6000L,
            "serviceStartMs" to 50L,
            "totalMs" to 6070L
        ), timing.snapshot())
    }

    @Test
    fun `already granted permission records zero user wait`() {
        var now = 0L
        val timing = NativeVpnStartTiming { now }
        timing.beginServiceStart()
        now = 100_000_000L
        val snapshot = timing.snapshot()
        assertEquals(false, snapshot["authorizationRequested"])
        assertEquals(0L, snapshot["authorizationWaitMs"])
        assertEquals(100L, snapshot["serviceStartMs"])
    }

    @Test
    fun `denied or cancelled authorization retains wait without a service start`() {
        var now = 0L
        val timing = NativeVpnStartTiming { now }
        timing.beginPermissionWait()
        now = 200_000_000L
        timing.endPermissionWait()
        now = 210_000_000L
        val snapshot = timing.snapshot()
        assertEquals(200L, snapshot["authorizationWaitMs"])
        assertEquals(0L, snapshot["serviceStartMs"])
        assertEquals(210L, snapshot["totalMs"])
    }

    @Test
    fun `repeated boundaries cannot reset a phase or mutate a captured snapshot`() {
        var now = 0L
        val timing = NativeVpnStartTiming { now }
        timing.beginPermissionWait()
        now = 100_000_000L
        timing.beginPermissionWait()
        timing.beginServiceStart()
        val captured = timing.snapshot()
        now = 300_000_000L
        timing.beginServiceStart()
        assertEquals(100L, captured["totalMs"])
        assertEquals(100L, timing.snapshot()["authorizationWaitMs"])
        assertEquals(200L, timing.snapshot()["serviceStartMs"])
    }

    @Test
    fun `request timings never share state`() {
        var now = 0L
        val old = NativeVpnStartTiming { now }
        old.beginPermissionWait()
        now = 100_000_000L
        val replacement = NativeVpnStartTiming { now }
        replacement.beginServiceStart()
        now = 150_000_000L
        assertEquals(150L, old.snapshot()["authorizationWaitMs"])
        assertEquals(0L, replacement.snapshot()["authorizationWaitMs"])
        assertEquals(50L, replacement.snapshot()["serviceStartMs"])
    }
}
