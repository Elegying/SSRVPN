package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationUpdatePolicyTest {
    @Test
    fun `traffic notifications are limited to sixty seconds`() {
        val policy = NotificationUpdatePolicy()

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
}
