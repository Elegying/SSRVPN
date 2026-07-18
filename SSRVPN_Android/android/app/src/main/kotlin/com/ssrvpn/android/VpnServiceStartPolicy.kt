package com.ssrvpn.android

import android.app.Service

enum class RejectedServiceStartAction {
    KEEP_SERVICE,
    STOP_IDLE_SERVICE
}

object VpnServiceStartPolicy {
    fun rejectedRequest(
        hasActiveSession: Boolean,
        newerStartInProgress: Boolean
    ): RejectedServiceStartAction =
        if (hasActiveSession || newerStartInProgress) {
            RejectedServiceStartAction.KEEP_SERVICE
        } else {
            RejectedServiceStartAction.STOP_IDLE_SERVICE
        }
}

fun SsrvpnVpnService.finishRejectedServiceStart(
    startId: Int,
    action: RejectedServiceStartAction
): Int {
    if (action == RejectedServiceStartAction.KEEP_SERVICE) {
        return Service.START_STICKY
    }
    stopSelfResult(startId)
    return Service.START_NOT_STICKY
}
