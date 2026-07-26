package com.ssrvpn.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DisconnectRecoveryCoordinatorTest {
    @Test
    fun `hands off foreground UI before a required process reset`() {
        assertTrue(
            DisconnectRecoveryCoordinator.shouldHandoff(
                foregroundUiRequested = true,
                processTerminationRequired = true
            )
        )
    }

    @Test
    fun `does not open UI for background disconnects or clean shutdowns`() {
        assertFalse(
            DisconnectRecoveryCoordinator.shouldHandoff(
                foregroundUiRequested = false,
                processTerminationRequired = true
            )
        )
        assertFalse(
            DisconnectRecoveryCoordinator.shouldHandoff(
                foregroundUiRequested = true,
                processTerminationRequired = false
            )
        )
    }
}
