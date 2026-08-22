package com.ssrvpn.android

import android.os.Handler
import android.util.Log
import java.util.concurrent.atomic.AtomicLong

/** Single source of truth for every bounded native VPN startup stage. */
internal object VpnStartBudget {
    const val BRIDGE_MS = 45_000L
    const val CANCEL_GRACE_MS = 1_000L
    const val API_HEALTH_MS = 20_000L
    const val API_POLL_MS = 250L
    // MihomoProxySelection performs at most four local API requests, each
    // with independent 1.5s connect/read timeouts.
    const val PROXY_SELECTION_MS = 12_000L
    private const val COORDINATION_GRACE_MS = 5_000L
    const val RESULT_MS =
        BRIDGE_MS + API_HEALTH_MS + PROXY_SELECTION_MS + COORDINATION_GRACE_MS
}

/** Coordinates bounded core recovery without owning the VPN service lifecycle. */
internal object CoreRecoveryCoordinator {
    private const val TAG = "SsrvpnVpn"
    // A recreated Service must not accept an older recovery Intent in the same process.
    private val recoveryGeneration = AtomicLong(0)

    fun cancelPendingRecovery() {
        recoveryGeneration.incrementAndGet()
    }

    fun shouldAcceptRestart(
        service: SsrvpnVpnService,
        attempt: Int,
        intentToken: Long?
    ): Boolean = CoreRecoveryPolicy.shouldAcceptRestart(
        attempt,
        intentToken,
        recoveryGeneration.get(),
        service.hasManualStopRequest()
    )

    fun recoverFromUnexpectedCoreExit(
        service: SsrvpnVpnService,
        request: CoreRecoveryRequest
    ) {
        val nextAttempt = nextAttemptAfterUnexpectedExit(request.attempt)
        if (nextAttempt == null) {
            Log.e(TAG, "Core recovery limit reached")
            stopWithFailure(service)
            return
        }
        if (service.hasManualStopRequest()) return

        val recoveryToken = recoveryGeneration.incrementAndGet()
        if (!NativeVpnSessionCoordinator.reserveRecovery(request.configPath)) return
        publishRecovering(service, nextAttempt, recoveryToken)

        service.stopForRecovery {
            if (!shouldRestart(service, nextAttempt, recoveryToken)) {
                if (service.hasPendingProcessTermination()) {
                    service.showCoreRecoveryFailedNotification()
                }
                return@stopForRecovery
            }
            launchRecovery(
                service,
                nextAttempt,
                recoveryToken,
                "Unable to restart VPN core"
            )
        }
    }

    fun nextAttemptAfterUnexpectedExit(currentAttempt: Int): Int? =
        CoreRecoveryPolicy.nextAttempt(currentAttempt)

    fun stopAfterStartFailure(
        service: SsrvpnVpnService,
        handler: Handler,
        recoveryAttempt: Int
    ) {
        val nextAttempt = CoreRecoveryPolicy.retryAfterStartFailure(recoveryAttempt)
        if (nextAttempt == null) {
            if (recoveryAttempt > 0) stopWithFailure(service) else service.stopAll()
            return
        }
        retryRecoveryAfterStartFailure(service, handler, nextAttempt)
    }

    private fun retryRecoveryAfterStartFailure(
        service: SsrvpnVpnService,
        handler: Handler,
        nextAttempt: Int
    ) {
        if (service.hasManualStopRequest() || service.hasPendingProcessTermination()) {
            stopWithFailure(service)
            return
        }

        val recoveryToken = recoveryGeneration.incrementAndGet()
        publishRecovering(service, nextAttempt, recoveryToken)

        service.stopForRecovery {
            val restart = Runnable {
                if (!shouldRestart(service, nextAttempt, recoveryToken)) return@Runnable
                launchRecovery(
                    service,
                    nextAttempt,
                    recoveryToken,
                    "Unable to perform final VPN recovery attempt"
                )
            }
            handler.postDelayed(
                restart,
                CoreRecoveryPolicy.retryDelayMillis(nextAttempt)
            )
        }
    }

    private fun publishRecovering(
        service: SsrvpnVpnService,
        attempt: Int,
        recoveryToken: Long
    ) = service.publishCoreRecovery(attempt) {
        CoreRecoveryPolicy.shouldPublishRecovery(
            recoveryToken,
            recoveryGeneration.get(),
            service.hasManualStopRequest(),
            service.hasPendingProcessTermination()
        )
    }

    private fun shouldRestart(
        service: SsrvpnVpnService,
        attempt: Int,
        recoveryToken: Long
    ): Boolean = CoreRecoveryPolicy.shouldAcceptRestart(
        attempt,
        recoveryToken,
        recoveryGeneration.get(),
        service.hasManualStopRequest()
    ) && !service.hasPendingProcessTermination()

    private fun launchRecovery(
        service: SsrvpnVpnService,
        attempt: Int,
        recoveryToken: Long,
        failureLog: String
    ) {
        try {
            val restartIntent = SsrvpnVpnService.createStartIntent(
                service,
                recoveryAttempt = attempt,
                recoveryToken = recoveryToken
            )
            // Recovery keeps this same Service in foreground, so deliver the
            // next command without attempting a new background FGS launch.
            service.startService(restartIntent)
        } catch (error: Exception) {
            val category = NativeCoreStartFailureCategory.from(error).logValue
            Log.e(TAG, "$failureLog cause=$category")
            NativeVpnSessionCoordinator.clearRecovery()
            service.showCoreRecoveryFailedNotification()
            service.stopSelf()
        }
    }

    private fun stopWithFailure(service: SsrvpnVpnService) {
        service.stopAll { service.showCoreRecoveryFailedNotification() }
    }
}
