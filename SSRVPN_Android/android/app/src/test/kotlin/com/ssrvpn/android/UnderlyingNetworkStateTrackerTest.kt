package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UnderlyingNetworkStateTrackerTest {
    @Test
    fun `available and validated state follows every non VPN network`() {
        val tracker = UnderlyingNetworkStateTracker<String>()

        tracker.update("wifi", validated = false)
        assertEquals(UnderlyingNetworkSnapshot(available = true, validated = false), tracker.snapshot())

        tracker.update("cellular", validated = true)
        assertEquals(UnderlyingNetworkSnapshot(available = true, validated = true), tracker.snapshot())

        tracker.remove("cellular")
        assertTrue(tracker.snapshot().available)
        assertFalse(tracker.snapshot().validated)

        tracker.remove("wifi")
        assertEquals(UnderlyingNetworkSnapshot(available = false, validated = false), tracker.snapshot())
    }
}
