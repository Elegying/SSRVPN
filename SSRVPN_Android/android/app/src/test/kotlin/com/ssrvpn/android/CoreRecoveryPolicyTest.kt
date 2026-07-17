package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreRecoveryPolicyTest {
    @Test
    fun `unexpected core exit retries exactly once`() {
        assertEquals(1, CoreRecoveryPolicy.nextAttempt(0))
        assertNull(CoreRecoveryPolicy.nextAttempt(1))
        assertNull(CoreRecoveryPolicy.nextAttempt(2))
    }

    @Test
    fun `recovery messages are explicit for users`() {
        assertEquals(
            "核心异常，正在自动恢复（1/1）",
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
}
