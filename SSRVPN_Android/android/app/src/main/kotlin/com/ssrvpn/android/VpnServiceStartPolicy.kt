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

/** Keeps asynchronous stop completions scoped to the service start they own. */
internal class VpnServiceStopGate {
    internal data class StopToken(
        val acceptedGeneration: Int,
        val stopGeneration: Int
    )

    private val lock = Any()
    @Volatile
    private var acceptedStartId = 0
    private var acceptedGeneration = 0
    private var stopGeneration = 0
    private var activeStop: StopToken? = null
    private var activeStopTargetStartId = 0

    fun acceptStart(startId: Int) = synchronized(lock) {
        acceptedStartId = startId
        acceptedGeneration++
    }

    fun beginOrJoinStop(): StopToken = synchronized(lock) {
        activeStop
            ?.takeIf { it.acceptedGeneration == acceptedGeneration }
            ?.let { return@synchronized it }
        val token = StopToken(acceptedGeneration, ++stopGeneration)
        activeStop = token
        activeStopTargetStartId = acceptedStartId
        token
    }

    fun includeRejectedStart(startId: Int) = synchronized(lock) {
        if (activeStop?.acceptedGeneration == acceptedGeneration) {
            activeStopTargetStartId = startId
        }
    }

    fun finishStop(token: StopToken): Int? = synchronized(lock) {
        if (activeStop != token) return@synchronized null
        activeStop = null
        if (token.acceptedGeneration != acceptedGeneration) {
            return@synchronized null
        }
        activeStopTargetStartId.takeIf { it > 0 }
    }
}

fun SsrvpnVpnService.finishRejectedServiceStart(
    startId: Int,
    hasActiveSession: Boolean,
    newerStartInProgress: Boolean
): Int {
    val action = VpnServiceStartPolicy.rejectedRequest(
        hasActiveSession,
        newerStartInProgress
    )
    if (action == RejectedServiceStartAction.KEEP_SERVICE) {
        return Service.START_STICKY
    }
    stopSelfResult(startId)
    return Service.START_NOT_STICKY
}
