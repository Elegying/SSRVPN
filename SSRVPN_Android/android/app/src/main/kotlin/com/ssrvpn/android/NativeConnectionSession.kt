package com.ssrvpn.android

import android.content.Context
import java.io.File
import java.util.UUID

internal data class NativeStartClaim(
    val id: String,
    val snapshot: NativeConnectionSnapshot
)

/**
 * Configuration identities owned by the live core or by an in-flight recovery.
 * A recovery reservation survives the intentional stop/restart gap so Flutter
 * never treats its config as an unused versioned snapshot.
 */
internal object NativeConnectionSession {
    @Volatile
    private var runningConfigPath: String? = null

    @Volatile
    private var recoveryConfigPath: String? = null

    @Volatile
    private var starting = false

    @Volatile
    private var startingConfigPath: String? = null

    @Volatile
    private var pendingStartClaimId: String? = null

    @Volatile
    private var pendingStartConfigPath: String? = null

    @Volatile
    private var stopping = false

    @Synchronized
    fun beginStarting(claimId: String?): Boolean {
        val pendingClaimId = pendingStartClaimId
        if (pendingClaimId != null && pendingClaimId != claimId) return false
        if (pendingClaimId == null && claimId != null) return false
        starting = true
        startingConfigPath = pendingStartConfigPath
        pendingStartClaimId = null
        pendingStartConfigPath = null
        return true
    }

    @Synchronized
    fun reserveStarting(configPath: String) {
        startingConfigPath = configPath
    }

    @Synchronized
    fun publishRunning(configPath: String) {
        runningConfigPath = configPath
        recoveryConfigPath = null
        startingConfigPath = null
        pendingStartClaimId = null
        pendingStartConfigPath = null
        starting = false
        stopping = false
    }

    @Synchronized
    fun reserveRecovery(configPath: String) {
        recoveryConfigPath = configPath
    }

    @Synchronized
    fun clearRunning() {
        runningConfigPath = null
        stopping = false
    }

    @Synchronized
    fun beginStopping() {
        stopping = true
    }

    @Synchronized
    fun clearRecovery() {
        recoveryConfigPath = null
    }

    @Synchronized
    fun clearStarting() {
        startingConfigPath = null
        pendingStartClaimId = null
        pendingStartConfigPath = null
        starting = false
    }

    fun claimPendingStart(
        configPath: String,
        gate: StartGenerationGate,
        running: () -> Boolean
    ): String? = gate.withCurrent {
        synchronized(this) {
            if (running() || isTransitioning() || !File(configPath).isFile) {
                return@withCurrent null
            }
            UUID.randomUUID().toString().also { claimId ->
                pendingStartClaimId = claimId
                pendingStartConfigPath = File(configPath).absolutePath
            }
        }
    }

    fun claimSnapshotForStart(
        context: Context,
        gate: StartGenerationGate,
        running: () -> Boolean
    ): NativeStartClaim? = gate.withCurrent {
        synchronized(this) {
            if (running() || isTransitioning()) return@withCurrent null
            val snapshot = NativeConnectionSnapshotStore.read(context)
                ?: return@withCurrent null
            if (!File(snapshot.configPath).isFile) return@withCurrent null
            val claimId = UUID.randomUUID().toString()
            pendingStartClaimId = claimId
            pendingStartConfigPath = File(snapshot.configPath).absolutePath
            NativeStartClaim(claimId, snapshot)
        }
    }

    fun releasePendingStart(claimId: String?, gate: StartGenerationGate) {
        if (claimId == null) return
        gate.withCurrent {
            synchronized(this) {
                if (pendingStartClaimId == claimId) {
                    pendingStartClaimId = null
                    pendingStartConfigPath = null
                }
            }
        }
    }

    fun prepareApiSecretRecovery(
        gate: StartGenerationGate,
        running: () -> Boolean,
        clearSnapshot: () -> Unit
    ): Boolean = gate.withCurrent {
        synchronized(this) {
            if (running() || starting || stopping || recoveryConfigPath != null) {
                return@withCurrent false
            }
            clearSnapshot()
            pendingStartClaimId = null
            pendingStartConfigPath = null
            true
        }
    }

    fun clearIdleSnapshot(
        context: Context,
        gate: StartGenerationGate,
        running: () -> Boolean,
        expectedGeneration: String?
    ): Boolean = gate.withCurrent {
        synchronized(this) {
            check(!running() && !isTransitioning()) {
                "Native VPN start or recovery is in progress"
            }
            NativeConnectionSnapshotStore.clearIfGeneration(
                context,
                expectedGeneration
            )
        }
    }

    @Synchronized
    fun protectedConfigPath(running: Boolean): String? =
        if (running) {
            runningConfigPath
        } else {
            recoveryConfigPath ?:
                startingConfigPath ?:
                pendingStartConfigPath ?:
                runningConfigPath.takeIf { stopping }
        }

    @Synchronized
    fun isTransitioning(): Boolean =
        starting || stopping || recoveryConfigPath != null || pendingStartClaimId != null

    @Synchronized
    fun snapshot(running: Boolean, sessionGeneration: Long): Map<String, Any?> =
        mapOf(
            "running" to running,
            "transitioning" to isTransitioning(),
            "protectedConfigPath" to protectedConfigPath(running),
            "protectedConfigTrusted" to (protectedConfigPath(running) != null),
            "sessionGeneration" to sessionGeneration.takeIf { running }
        )

    fun snapshotConsistently(
        gate: StartGenerationGate,
        running: () -> Boolean
    ): Map<String, Any?> {
        while (true) {
            val token = gate.current()
            var state: Map<String, Any?>? = null
            if (gate.runIfCurrent(token) {
                    synchronized(this) {
                        state = snapshot(running(), token)
                    }
                }
            ) {
                return checkNotNull(state)
            }
        }
    }

    fun commitIdleSnapshot(
        context: Context,
        gate: StartGenerationGate,
        running: () -> Boolean,
        snapshot: NativeConnectionSnapshot
    ): String? {
        val token = gate.current()
        var generation: String? = null
        gate.runIfCurrent(token) {
            synchronized(this) {
                if (!running() &&
                    !isTransitioning() &&
                    protectedConfigPath(false) == null
                ) {
                    generation = NativeConnectionSnapshotStore.write(
                        context,
                        snapshot
                    )
                }
            }
        }
        return generation
    }
}
