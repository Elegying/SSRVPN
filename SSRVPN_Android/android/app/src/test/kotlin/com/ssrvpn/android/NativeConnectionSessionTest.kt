package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeConnectionSessionTest {
    @Test
    fun `tile start cannot interleave with retention reference capture`() {
        val gate = StartGenerationGate()
        val config = java.nio.file.Files.createTempFile("ssrvpn-rule-tile", ".yaml").toFile()
        config.writeText("rule-providers: {p: {path: ./providers/bundles/1.0.0/a.yaml}}")
        val executor = java.util.concurrent.Executors.newFixedThreadPool(2)
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val claimAttempted = java.util.concurrent.CountDownLatch(1)
        NativeConnectionSession.clearRecovery()
        NativeConnectionSession.clearStarting()
        NativeConnectionSession.clearRunning()
        try {
            val capture = executor.submit<List<String>?> {
                NativeConnectionSession.ruleRetentionConfigPaths(gate, { false }) {
                    entered.countDown()
                    check(release.await(2, java.util.concurrent.TimeUnit.SECONDS))
                    config.absolutePath
                }
            }
            assertTrue(entered.await(1, java.util.concurrent.TimeUnit.SECONDS))
            val claim = executor.submit<String?> {
                claimAttempted.countDown()
                NativeConnectionSession.claimPendingStart(config.absolutePath, gate) { false }
            }
            assertTrue(claimAttempted.await(1, java.util.concurrent.TimeUnit.SECONDS))
            var blocked = false
            try {
                claim.get(50, java.util.concurrent.TimeUnit.MILLISECONDS)
            } catch (_: java.util.concurrent.TimeoutException) {
                blocked = true
            }
            assertTrue(blocked)
            release.countDown()
            assertEquals(listOf(config.absolutePath),
                capture.get(1, java.util.concurrent.TimeUnit.SECONDS))
            assertTrue(claim.get(1, java.util.concurrent.TimeUnit.SECONDS) != null)
            assertEquals(config.absolutePath,
                NativeConnectionSession.snapshotConsistently(gate) { false }["protectedConfigPath"])
        } finally {
            release.countDown()
            executor.shutdownNow()
            NativeConnectionSession.clearStarting()
            config.delete()
        }
    }

    @Test
    fun `rule collection rejects native transitions and propagates unreadable snapshots`() {
        val gate = StartGenerationGate()
        NativeConnectionSession.clearRecovery()
        NativeConnectionSession.clearStarting()
        NativeConnectionSession.clearRunning()
        assertEquals(listOf("/data/old-tile.yaml"),
            NativeConnectionSession.ruleRetentionConfigPaths(gate, { false }) {
                "/data/old-tile.yaml"
            })
        assertNull(NativeConnectionSession.ruleRetentionConfigPaths(gate, { true }) {
            error("Must not inspect a running snapshot")
        })
        NativeConnectionSession.reserveRecovery("/data/old-tile.yaml")
        assertNull(NativeConnectionSession.ruleRetentionConfigPaths(gate, { false }) {
            error("Must not inspect a recovery reservation")
        })
        NativeConnectionSession.clearRecovery()
        assertTrue(NativeConnectionSession.beginStarting(null))
        try {
            assertNull(NativeConnectionSession.ruleRetentionConfigPaths(gate, { false }) {
                error("Must not inspect a starting snapshot")
            })
        } finally {
            NativeConnectionSession.clearStarting()
        }
        var propagated = false
        try {
            NativeConnectionSession.ruleRetentionConfigPaths(gate, { false }) {
                error("Keystore unavailable")
            }
        } catch (_: IllegalStateException) {
            propagated = true
        }
        assertTrue(propagated)
    }

    @Test
    fun `user stop cause survives cleanup and resets on the next accepted start`() {
        NativeConnectionSession.clearRecovery()
        NativeConnectionSession.clearStarting()
        NativeConnectionSession.publishRunning("/data/config-active.yaml")
        NativeConnectionSession.beginStopping(userInitiated = true)
        NativeConnectionSession.beginStopping()
        NativeConnectionSession.clearRunning()
        val stopped = NativeConnectionSession.snapshot(false, 2)
        assertEquals(true, stopped["manuallyStopped"])
        assertEquals(false, stopped["transitioning"])

        assertTrue(NativeConnectionSession.beginStarting(null))
        assertEquals(false, NativeConnectionSession.snapshot(false, 3)["manuallyStopped"])
        NativeConnectionSession.publishRunning("/data/config-next.yaml")
        NativeConnectionSession.beginStopping()
        NativeConnectionSession.clearRunning()
        assertEquals(false, NativeConnectionSession.snapshot(false, 4)["manuallyStopped"])
    }

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
        assertTrue(running["protectedConfigTrusted"] as Boolean)

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
