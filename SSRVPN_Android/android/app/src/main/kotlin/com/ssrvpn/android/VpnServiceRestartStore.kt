package com.ssrvpn.android

import android.content.Context

internal object StickyVpnRestartPolicy {
    fun shouldAccept(hasExplicitIntent: Boolean, manuallyStopped: Boolean): Boolean =
        hasExplicitIntent || !manuallyStopped
}

internal object VpnServiceRestartStore {
    private const val STORAGE_NAME = "ssrvpn_vpn_service_restart"
    private const val KEY_MANUALLY_STOPPED = "manually_stopped"

    fun shouldAcceptStickyRestart(context: Context): Boolean =
        StickyVpnRestartPolicy.shouldAccept(
            hasExplicitIntent = false,
            manuallyStopped = preferences(context).getBoolean(KEY_MANUALLY_STOPPED, false)
        )

    fun recordExplicitStart(context: Context): Boolean =
        replace(context, manuallyStopped = false)

    fun recordManualStop(context: Context): Boolean =
        replace(context, manuallyStopped = true)

    private fun replace(context: Context, manuallyStopped: Boolean): Boolean {
        val editor = preferences(context).edit()
            .putBoolean(KEY_MANUALLY_STOPPED, manuallyStopped)
        return editor.commit()
    }

    private fun preferences(context: Context) =
        context.getSharedPreferences(STORAGE_NAME, Context.MODE_PRIVATE)
}
