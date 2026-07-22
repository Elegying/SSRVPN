package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreRecoveryPolicyTest {
    @Test
    fun `unexpected core exit allows two bounded retries`() {
        assertEquals(1, CoreRecoveryPolicy.nextAttempt(0))
        assertEquals(2, CoreRecoveryPolicy.nextAttempt(1))
        assertNull(CoreRecoveryPolicy.nextAttempt(2))
    }

    @Test
    fun `recovery messages are explicit for users`() {
        assertEquals(
            "核心异常，正在自动恢复（1/2）",
            CoreRecoveryPolicy.recoveringMessage(1)
        )
        assertEquals(
            "核心异常，自动恢复失败，请重新连接",
            CoreRecoveryPolicy.failureMessage
        )
    }

    @Test
    fun `queued recovery is rejected after a manual stop or token change`() {
        assertTrue(
            CoreRecoveryPolicy.shouldAcceptRestart(
                attempt = 1,
                intentToken = 8,
                currentToken = 8,
                manualStopRequested = false
            )
        )
        assertFalse(
            CoreRecoveryPolicy.shouldAcceptRestart(
                attempt = 1,
                intentToken = 8,
                currentToken = 9,
                manualStopRequested = false
            )
        )
        assertFalse(
            CoreRecoveryPolicy.shouldAcceptRestart(
                attempt = 1,
                intentToken = 8,
                currentToken = 8,
                manualStopRequested = true
            )
        )
    }

    @Test
    fun `stale recovery never stops a newer active or starting service`() {
        assertEquals(
            RejectedServiceStartAction.KEEP_SERVICE,
            VpnServiceStartPolicy.rejectedRequest(
                hasActiveSession = true,
                newerStartInProgress = false
            )
        )
        assertEquals(
            RejectedServiceStartAction.KEEP_SERVICE,
            VpnServiceStartPolicy.rejectedRequest(
                hasActiveSession = false,
                newerStartInProgress = true
            )
        )
        assertEquals(
            RejectedServiceStartAction.STOP_IDLE_SERVICE,
            VpnServiceStartPolicy.rejectedRequest(
                hasActiveSession = false,
                newerStartInProgress = false
            )
        )
    }

    @Test
    fun `rejected start lease stops the idle foreground service request`() {
        assertEquals(
            RejectedServiceStartAction.STOP_IDLE_SERVICE,
            VpnServiceStartPolicy.rejectedRequest(
                hasActiveSession = false,
                newerStartInProgress = false
            )
        )
    }

    @Test
    fun `recovery transition notification survives ordinary stop invalidation`() {
        val notificationGate = NotificationGenerationGate()
        val ordinaryNotification = notificationGate.capture()
        notificationGate.invalidate()

        assertFalse(notificationGate.isCurrent(ordinaryNotification))
        assertTrue(
            CoreRecoveryPolicy.shouldPublishRecovery(
                recoveryToken = 12,
                currentToken = 12,
                manualStopRequested = false,
                processTerminationPending = false
            )
        )
        assertFalse(
            CoreRecoveryPolicy.shouldPublishRecovery(
                recoveryToken = 12,
                currentToken = 13,
                manualStopRequested = false,
                processTerminationPending = false
            )
        )
        assertFalse(
            CoreRecoveryPolicy.shouldPublishRecovery(
                recoveryToken = 12,
                currentToken = 12,
                manualStopRequested = true,
                processTerminationPending = false
            )
        )
    }
}
