package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationUpdatePolicyTest {
    @Test
    fun `traffic notifications are limited to sixty seconds`() {
        val policy = NotificationUpdatePolicy()

        assertEquals(10_000L, policy.initialRefreshDelayMillis)
        assertEquals(60_000L, policy.refreshIntervalMillis)
        assertTrue(policy.shouldScheduleTrafficRefresh())
    }

    @Test
    fun `screen off stops traffic refresh until screen on`() {
        val policy = NotificationUpdatePolicy()

        policy.onScreenStateChanged(false)
        assertFalse(policy.shouldScheduleTrafficRefresh())

        policy.onScreenStateChanged(true)
        assertTrue(policy.shouldScheduleTrafficRefresh())
    }

    @Test
    fun `traffic rates are normalized by elapsed time`() {
        val policy = NotificationUpdatePolicy()

        assertEquals(1_000L, policy.bytesPerSecond(60_000L, 60_000L))
        assertEquals(0L, policy.bytesPerSecond(-1L, 60_000L))
        assertEquals(0L, policy.bytesPerSecond(1_000L, 0L))
    }

    @Test
    fun `identical notification content is published only once`() {
        val policy = NotificationUpdatePolicy()
        val state = VpnNotificationState(
            nodeName = "Tokyo",
            connected = true,
            statusText = null,
            uploadRate = 0L,
            downloadRate = 0L,
            sessionUpload = 0L,
            sessionDownload = 0L,
            connectionStartedAt = 100L
        )

        assertTrue(policy.shouldPublish(state))
        assertFalse(policy.shouldPublish(state))
        assertTrue(policy.shouldPublish(state.copy(downloadRate = 1L)))
    }

    @Test
    fun `notification publication state can be reset for a new session`() {
        val policy = NotificationUpdatePolicy()
        val state = VpnNotificationState(
            nodeName = "SSRVPN",
            connected = false,
            statusText = null,
            uploadRate = 0L,
            downloadRate = 0L,
            sessionUpload = 0L,
            sessionDownload = 0L,
            connectionStartedAt = 100L
        )

        assertTrue(policy.shouldPublish(state))
        assertFalse(policy.shouldPublish(state))
        policy.resetPublishedState()
        assertTrue(policy.shouldPublish(state))
    }
}
