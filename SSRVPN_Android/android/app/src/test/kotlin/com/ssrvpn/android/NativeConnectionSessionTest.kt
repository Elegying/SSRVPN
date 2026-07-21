package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeConnectionSessionTest {
    @Test
    fun `recovery reservation survives the native stop gap`() {
        val gate = StartGenerationGate()
        val runningToken = gate.beginStart()
        NativeConnectionSession.clearRecovery()
        NativeConnectionSession.clearStarting()
        NativeConnectionSession.publishRunning("/data/config-active.yaml")

        val running = NativeConnectionSession.snapshotConsistently(gate) { true }
        assertTrue(running["running"] as Boolean)
        assertEquals(runningToken, running["sessionGeneration"])
        assertEquals("/data/config-active.yaml", running["protectedConfigPath"])

        NativeConnectionSession.beginStopping()
        val stopping = NativeConnectionSession.snapshotConsistently(gate) { false }
        assertTrue(stopping["transitioning"] as Boolean)
        assertEquals("/data/config-active.yaml", stopping["protectedConfigPath"])

        NativeConnectionSession.reserveRecovery("/data/config-active.yaml")
        gate.invalidate()
        NativeConnectionSession.clearRunning()

        val recovering = NativeConnectionSession.snapshotConsistently(gate) { false }
        assertFalse(recovering["running"] as Boolean)
        assertNull(recovering["sessionGeneration"])
        assertEquals("/data/config-active.yaml", recovering["protectedConfigPath"])

        NativeConnectionSession.clearRecovery()
        assertTrue(NativeConnectionSession.beginStarting(null))
        NativeConnectionSession.reserveStarting("/data/config-starting.yaml")
        val starting = NativeConnectionSession.snapshotConsistently(gate) { false }
        assertTrue(starting["transitioning"] as Boolean)
        assertEquals("/data/config-starting.yaml", starting["protectedConfigPath"])
        NativeConnectionSession.clearStarting()
    }

    @Test
    fun `pending start claim protects config until service consumes it`() {
        val gate = StartGenerationGate()
        val config = java.io.File.createTempFile("ssrvpn-claim", ".yaml")
        config.writeText("proxies: []")
        NativeConnectionSession.clearRecovery()
        NativeConnectionSession.clearStarting()

        val claimId = NativeConnectionSession.claimPendingStart(
            config.absolutePath,
            gate,
            { false }
        )
        assertTrue(claimId != null)
        val pending = NativeConnectionSession.snapshotConsistently(gate) { false }
        assertTrue(pending["transitioning"] as Boolean)
        assertEquals(config.absolutePath, pending["protectedConfigPath"])

        var accepted = false
        gate.beginStart {
            accepted = NativeConnectionSession.beginStarting(claimId)
        }
        assertTrue(accepted)
        val starting = NativeConnectionSession.snapshotConsistently(gate) { false }
        assertTrue(starting["transitioning"] as Boolean)
        assertEquals(config.absolutePath, starting["protectedConfigPath"])

        NativeConnectionSession.clearStarting()
        config.delete()
    }

    @Test
    fun `released activity claim is rejected when service handles its queued start`() {
        val gate = StartGenerationGate()
        val config = java.io.File.createTempFile("ssrvpn-released-claim", ".yaml")
        config.writeText("proxies: []")
        NativeConnectionSession.clearRecovery()
        NativeConnectionSession.clearStarting()

        val claimId = NativeConnectionSession.claimPendingStart(
            config.absolutePath,
            gate,
            { false }
        )
        assertTrue(claimId != null)

        NativeConnectionSession.releasePendingStart(claimId, gate)
        var accepted = false
        gate.beginStart {
            accepted = NativeConnectionSession.beginStarting(claimId)
        }

        assertFalse(accepted)
        assertFalse(
            NativeConnectionSession.snapshotConsistently(gate) { false }["transitioning"]
                as Boolean
        )
        config.delete()
    }

    @Test
    fun `API secret recovery clears an idle pending claim before it can start`() {
        val gate = StartGenerationGate()
        val config = java.io.File.createTempFile("ssrvpn-secret-recovery", ".yaml")
        config.writeText("proxies: []")
        NativeConnectionSession.clearRecovery()
        NativeConnectionSession.clearStarting()

        val claimId = NativeConnectionSession.claimPendingStart(
            config.absolutePath,
            gate,
            { false }
        )
        var snapshotCleared = false

        val prepared = NativeConnectionSession.prepareApiSecretRecovery(
            gate,
            { false },
            { snapshotCleared = true }
        )

        assertTrue(prepared)
        assertTrue(snapshotCleared)
        var accepted = false
        gate.beginStart {
            accepted = NativeConnectionSession.beginStarting(claimId)
        }
        assertFalse(accepted)
        assertFalse(
            NativeConnectionSession.snapshotConsistently(gate) { false }["transitioning"]
                as Boolean
        )
        config.delete()
    }

    @Test
    fun `API secret recovery rejects a live native session without clearing state`() {
        val gate = StartGenerationGate()
        val runningToken = gate.beginStart()
        NativeConnectionSession.clearRecovery()
        NativeConnectionSession.clearStarting()
        NativeConnectionSession.publishRunning("/data/config-running.yaml")
        var snapshotCleared = false

        val prepared = NativeConnectionSession.prepareApiSecretRecovery(
            gate,
            { true },
            { snapshotCleared = true }
        )

        assertFalse(prepared)
        assertFalse(snapshotCleared)
        val state = NativeConnectionSession.snapshotConsistently(gate) { true }
        assertEquals(runningToken, state["sessionGeneration"])
        assertEquals("/data/config-running.yaml", state["protectedConfigPath"])
        NativeConnectionSession.clearRunning()
    }
}
