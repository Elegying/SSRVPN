package com.ssrvpn.android

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
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

    @Test
    fun `snapshot cannot observe a partially updated traffic sample`() {
        var tx = 100L
        var rx = 200L
        var now = 1_000L
        val tracker = VpnTrafficTracker({ tx }, { rx }, { now })
        tracker.reset()
        tx = 2_100L
        rx = 4_200L
        now = 3_000L

        val firstRateCalculated = CountDownLatch(1)
        val allowUpdateToFinish = CountDownLatch(1)
        val executor = Executors.newFixedThreadPool(2)
        try {
            var calculation = 0
            val update = executor.submit {
                tracker.update { delta, elapsed ->
                    calculation++
                    if (calculation == 1) {
                        firstRateCalculated.countDown()
                        allowUpdateToFinish.await(1, TimeUnit.SECONDS)
                    }
                    delta * 1_000L / elapsed
                }
            }
            assertTrue(firstRateCalculated.await(1, TimeUnit.SECONDS))

            val snapshotAttempted = CountDownLatch(1)
            val snapshot = executor.submit<VpnTrafficSnapshot> {
                snapshotAttempted.countDown()
                tracker.snapshot()
            }
            assertTrue(snapshotAttempted.await(1, TimeUnit.SECONDS))
            Thread.sleep(25L)
            assertFalse(
                "snapshot returned while update held a partial sample",
                snapshot.isDone
            )

            allowUpdateToFinish.countDown()
            update.get(1, TimeUnit.SECONDS)
            assertEquals(
                VpnTrafficSnapshot(
                    uploadRate = 1_000L,
                    downloadRate = 2_000L,
                    sessionUpload = 2_000L,
                    sessionDownload = 4_000L
                ),
                snapshot.get(1, TimeUnit.SECONDS)
            )
        } finally {
            allowUpdateToFinish.countDown()
            executor.shutdownNow()
        }
    }
}
