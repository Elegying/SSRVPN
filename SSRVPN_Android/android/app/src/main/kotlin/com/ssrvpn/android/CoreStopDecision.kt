package com.ssrvpn.android

internal data class CoreStopDecision(
    val terminateProcess: Boolean,
    val clearRunningSession: Boolean,
    val dataPortsLingering: Boolean
) {
    fun terminationMessage(dataPorts: Collection<Int>): String = if (dataPortsLingering) {
        "Bridge stopped but data plane ports ${dataPorts.joinToString()} still listen after the release grace period"
    } else {
        "Bridge shutdown could not be verified"
    }

    companion object {
        // The embedded controller has its own HTTP server and is recreated on
        // the next start. Only data-plane listeners prove whether proxy
        // traffic resources were actually released.
        fun afterBridgeCheck(
            pendingStartStopped: Boolean,
            bridgeStopped: Boolean,
            dataPorts: Collection<Int>,
            waitUntilPortsReleased: (Collection<Int>) -> Boolean =
                CorePortReleaseVerifier::waitUntilAllReleased
        ): CoreStopDecision = evaluate(
            pendingStartStopped = pendingStartStopped,
            bridgeStopped = bridgeStopped,
            dataPortsReleased = bridgeStopped && waitUntilPortsReleased(dataPorts)
        )

        fun evaluate(
            pendingStartStopped: Boolean,
            bridgeStopped: Boolean,
            dataPortsReleased: Boolean
        ): CoreStopDecision {
            val bridgeShutdownVerified = pendingStartStopped && bridgeStopped
            val shutdownCompleted = bridgeShutdownVerified && dataPortsReleased
            return CoreStopDecision(
                terminateProcess = !shutdownCompleted,
                clearRunningSession = shutdownCompleted,
                dataPortsLingering = bridgeShutdownVerified && !dataPortsReleased
            )
        }
    }
}

internal object StopOperationRunner {
    fun run(
        initiallyRequiresTermination: Boolean,
        cleanup: () -> Boolean,
        onTerminationRequired: () -> Unit,
        complete: () -> Unit,
        scheduleTermination: () -> Unit
    ): Throwable? {
        var terminationRequired = initiallyRequiresTermination
        var cleanupFailure: Throwable? = null
        try {
            val cleanupRequiresTermination = cleanup()
            terminationRequired = terminationRequired || cleanupRequiresTermination
        } catch (error: Throwable) {
            terminationRequired = true
            cleanupFailure = error
        } finally {
            try {
                if (terminationRequired) onTerminationRequired()
            } finally {
                try {
                    complete()
                } finally {
                    if (terminationRequired) scheduleTermination()
                }
            }
        }
        return cleanupFailure
    }
}
