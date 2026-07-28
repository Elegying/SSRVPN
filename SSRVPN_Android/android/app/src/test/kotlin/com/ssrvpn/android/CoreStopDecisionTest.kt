package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreStopDecisionTest {
    @Test
    fun `terminates only after bridge stopped but API port exceeded its grace period`() {
        val decision = CoreStopDecision.afterBridgeCheck(
            pendingStartStopped = true,
            bridgeStopped = true,
            apiPort = 9090,
            waitUntilPortReleased = { false }
        )

        assertTrue(decision.terminateProcess)
        assertFalse(decision.clearRunningSession)
        assertTrue(decision.apiPortLingering)
        assertTrue(decision.terminationMessage(9090).contains("API port 9090"))
    }

    @Test
    fun `completes normally after bridge and API port both stop`() {
        val decision = CoreStopDecision.afterBridgeCheck(
            pendingStartStopped = true,
            bridgeStopped = true,
            apiPort = 9090,
            waitUntilPortReleased = { true }
        )

        assertFalse(decision.terminateProcess)
        assertTrue(decision.clearRunningSession)
        assertFalse(decision.apiPortLingering)
    }

    @Test
    fun `terminates app when bridge stop cannot be verified`() {
        val decision = CoreStopDecision.evaluate(
            pendingStartStopped = true,
            bridgeStopped = false,
            apiPortReleased = false
        )

        assertTrue(decision.terminateProcess)
        assertFalse(decision.clearRunningSession)
    }

    @Test
    fun `terminates app when a pending start cannot be cancelled`() {
        val decision = CoreStopDecision.evaluate(
            pendingStartStopped = false,
            bridgeStopped = true,
            apiPortReleased = true
        )

        assertTrue(decision.terminateProcess)
        assertFalse(decision.clearRunningSession)
    }

    @Test
    fun `cleanup exception still hands off completes and schedules termination`() {
        val failure = IllegalStateException("cleanup failed before returning a decision")
        val events = mutableListOf<String>()

        val observedFailure = StopOperationRunner.run(
            initiallyRequiresTermination = false,
            cleanup = {
                events += "cleanup"
                throw failure
            },
            onTerminationRequired = { events += "handoff" },
            complete = { events += "complete" },
            scheduleTermination = { events += "kill" }
        )

        assertSame(failure, observedFailure)
        assertEquals(listOf("cleanup", "handoff", "complete", "kill"), events)
    }

    @Test
    fun `preexisting termination requirement does not skip cleanup`() {
        val events = mutableListOf<String>()

        val observedFailure = StopOperationRunner.run(
            initiallyRequiresTermination = true,
            cleanup = {
                events += "cleanup"
                false
            },
            onTerminationRequired = { events += "handoff" },
            complete = { events += "complete" },
            scheduleTermination = { events += "kill" }
        )

        assertEquals(null, observedFailure)
        assertEquals(listOf("cleanup", "handoff", "complete", "kill"), events)
    }
}
