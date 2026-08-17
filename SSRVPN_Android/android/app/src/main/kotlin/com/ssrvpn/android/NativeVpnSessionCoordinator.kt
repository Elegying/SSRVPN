package com.ssrvpn.android

import android.content.Context
import android.content.Intent

/** Owns cross-entry-point native session claims and snapshot mutations. */
internal object NativeVpnSessionCoordinator {
    fun beginStart(claimId: String?): Long? {
        var accepted = false
        val token = SsrvpnVpnService.startGeneration.beginStart {
            accepted = NativeConnectionSession.beginStarting(claimId)
        }
        return token.takeIf { accepted }
    }

    fun connectionState(): Map<String, Any?> {
        val state = NativeConnectionSession.snapshotConsistently(
            SsrvpnVpnService.startGeneration
        ) {
            SsrvpnVpnService.isRunning
        }
        val underlying = SsrvpnVpnService.underlyingNetworkSnapshot()
        return state + mapOf(
            "underlyingNetworkAvailable" to underlying?.available,
            "underlyingNetworkValidated" to underlying?.validated
        )
    }

    fun diagnostics(): Map<String, Any?> {
        val service = SsrvpnVpnService.instance
        val operationBusy = SsrvpnVpnService.isCoreOperationBusy()
        val unavailableState = if (operationBusy) null else false
        val runtime = service?.runtimeDiagnosticsSnapshot() ?: NativeRuntimeDiagnostics(
            serviceRunning = SsrvpnVpnService.isRunning,
            operationBusy = operationBusy,
            tunEstablished = unavailableState,
            bridgeReady = unavailableState,
            protectMonitorAlive = unavailableState
        )
        return connectionState() + runtime.toMap()
    }

    fun commitIdleSnapshot(
        context: Context,
        snapshot: NativeConnectionSnapshot
    ): String? = NativeConnectionSession.commitIdleSnapshot(
        context,
        SsrvpnVpnService.startGeneration,
        { SsrvpnVpnService.isRunning },
        snapshot
    )

    fun claimSnapshotForStart(context: Context): NativeStartClaim? =
        NativeConnectionSession.claimSnapshotForStart(
            context,
            SsrvpnVpnService.startGeneration,
            { SsrvpnVpnService.isRunning }
        )

    fun claimPendingStart(intent: Intent): String? {
        val payload = NativeStartPayloadRegistry.peek(
            intent.getStringExtra(SsrvpnVpnService.EXTRA_START_PAYLOAD_ID)
        ) ?: return null
        val claimId = NativeConnectionSession.claimPendingStart(
            payload.configPath,
            SsrvpnVpnService.startGeneration,
            { SsrvpnVpnService.isRunning }
        )
        claimId?.let { intent.putExtra(SsrvpnVpnService.EXTRA_START_CLAIM_ID, it) }
        return claimId
    }

    fun releasePendingStart(claimId: String?) =
        NativeConnectionSession.releasePendingStart(
            claimId,
            SsrvpnVpnService.startGeneration
        )

    fun reserveRecovery(configPath: String): Boolean =
        SsrvpnVpnService.startGeneration.withCurrent {
            if (!SsrvpnVpnService.isRunning) return@withCurrent false
            NativeConnectionSession.reserveRecovery(configPath)
            true
        }

    fun clearRecovery() = SsrvpnVpnService.startGeneration.withCurrent {
        NativeConnectionSession.clearRecovery()
    }

    fun clearIdleSnapshot(context: Context, expectedGeneration: String?): Boolean =
        NativeConnectionSession.clearIdleSnapshot(
            context,
            SsrvpnVpnService.startGeneration,
            { SsrvpnVpnService.isRunning },
            expectedGeneration
        )

    fun prepareApiSecretRecovery(context: Context): Boolean =
        NativeConnectionSession.prepareApiSecretRecovery(
            SsrvpnVpnService.startGeneration,
            { SsrvpnVpnService.isRunning },
            { NativeConnectionSnapshotStore.clearAll(context) }
        )
}
