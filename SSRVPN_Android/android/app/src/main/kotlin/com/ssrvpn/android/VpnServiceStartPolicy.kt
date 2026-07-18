package com.ssrvpn.android

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
