package com.ssrvpn.android

internal data class CoreStopDecision(
    val terminateProcess: Boolean,
    val clearRunningSession: Boolean,
    val apiPortLingering: Boolean
) {
    fun terminationMessage(apiPort: Int): String = if (apiPortLingering) {
        "Bridge stopped but API port $apiPort still listens after the release grace period"
    } else {
        "Bridge shutdown could not be verified"
    }

    companion object {
        fun afterBridgeCheck(
            pendingStartStopped: Boolean,
            bridgeStopped: Boolean,
            apiPort: Int,
            waitUntilPortReleased: (Int) -> Boolean =
                CorePortReleaseVerifier::waitUntilReleased
        ): CoreStopDecision = evaluate(
            pendingStartStopped = pendingStartStopped,
            bridgeStopped = bridgeStopped,
            apiPortReleased = bridgeStopped && waitUntilPortReleased(apiPort)
        )

        fun evaluate(
            pendingStartStopped: Boolean,
            bridgeStopped: Boolean,
            apiPortReleased: Boolean
        ): CoreStopDecision {
            val bridgeShutdownVerified = pendingStartStopped && bridgeStopped
            val shutdownCompleted = bridgeShutdownVerified && apiPortReleased
            return CoreStopDecision(
                terminateProcess = !shutdownCompleted,
                clearRunningSession = shutdownCompleted,
                apiPortLingering = bridgeShutdownVerified && !apiPortReleased
            )
        }
    }
}
