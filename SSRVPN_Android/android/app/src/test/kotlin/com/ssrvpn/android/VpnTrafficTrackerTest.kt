package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Test

class VpnTrafficTrackerTest {
    @Test
    fun `traffic rates and session totals share one monotonic snapshot`() {
        var tx = 100L
        var rx = 200L
        var now = 1_000L
        val tracker = VpnTrafficTracker({ tx }, { rx }, { now })

        tracker.reset()
        tx = 2_100L
        rx = 4_200L
        now = 3_000L
        tracker.update { delta, elapsed -> delta * 1_000L / elapsed }

        assertEquals(
            VpnTrafficSnapshot(
                uploadRate = 1_000L,
                downloadRate = 2_000L,
                sessionUpload = 2_000L,
                sessionDownload = 4_000L
            ),
            tracker.snapshot()
        )
    }
}
