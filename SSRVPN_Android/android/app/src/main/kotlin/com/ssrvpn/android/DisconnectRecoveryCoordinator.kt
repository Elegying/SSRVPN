package com.ssrvpn.android

import android.content.Context

internal object DisconnectRecoveryCoordinator {
    fun shouldHandoff(
        foregroundUiRequested: Boolean,
        processTerminationRequired: Boolean
    ): Boolean = foregroundUiRequested && processTerminationRequired

    fun handoffIfNeeded(context: Context, preserveForegroundUi: Boolean) {
        if (shouldHandoff(
                preserveForegroundUi,
                processTerminationRequired = true
            )
        ) {
            DisconnectRecoveryActivity.handoff(context)
        }
    }
}
