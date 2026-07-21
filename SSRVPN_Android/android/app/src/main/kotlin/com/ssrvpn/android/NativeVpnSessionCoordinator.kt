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

    fun connectionState(): Map<String, Any?> =
        NativeConnectionSession.snapshotConsistently(SsrvpnVpnService.startGeneration) {
            SsrvpnVpnService.isRunning
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
        val configPath = intent.getStringExtra(SsrvpnVpnService.EXTRA_CONFIG_PATH)
            ?: return null
        val claimId = NativeConnectionSession.claimPendingStart(
            configPath,
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
