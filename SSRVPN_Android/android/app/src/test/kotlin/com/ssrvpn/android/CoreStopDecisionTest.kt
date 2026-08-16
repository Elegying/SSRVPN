package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreStopDecisionTest {
    @Test
    fun `terminates after bridge stopped but data plane ports exceeded their grace period`() {
        val decision = CoreStopDecision.afterBridgeCheck(
            pendingStartStopped = true,
            bridgeStopped = true,
            dataPorts = listOf(7890, 7891),
            waitUntilPortsReleased = { false }
        )

        assertTrue(decision.terminateProcess)
        assertFalse(decision.clearRunningSession)
        assertTrue(decision.dataPortsLingering)
        assertTrue(decision.terminationMessage(listOf(7890, 7891)).contains("7890, 7891"))
    }

    @Test
    fun `completes normally after bridge and data plane ports stop`() {
        val decision = CoreStopDecision.afterBridgeCheck(
            pendingStartStopped = true,
            bridgeStopped = true,
            dataPorts = listOf(7890, 7891),
            waitUntilPortsReleased = { true }
        )

        assertFalse(decision.terminateProcess)
        assertTrue(decision.clearRunningSession)
        assertFalse(decision.dataPortsLingering)
    }

    @Test
    fun `terminates app when bridge stop cannot be verified`() {
        val decision = CoreStopDecision.evaluate(
            pendingStartStopped = true,
            bridgeStopped = false,
            dataPortsReleased = false
        )

        assertTrue(decision.terminateProcess)
        assertFalse(decision.clearRunningSession)
    }

    @Test
    fun `terminates app when a pending start cannot be cancelled`() {
        val decision = CoreStopDecision.evaluate(
            pendingStartStopped = false,
            bridgeStopped = true,
            dataPortsReleased = true
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
