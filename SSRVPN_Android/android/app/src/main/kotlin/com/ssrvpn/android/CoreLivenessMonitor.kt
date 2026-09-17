package com.ssrvpn.android

internal data class CoreLivenessOutcome(
    val unexpectedExit: Boolean,
    val recoveryAttempt: Int
)

internal object CoreLivenessMonitor {
    private const val MAX_CONSECUTIVE_API_FAILURES = 3
    private const val POLL_INTERVAL_MILLIS = 3_000L

    fun waitForUnexpectedExit(
        startToken: Long,
        currentGeneration: () -> Long,
        isRunning: () -> Boolean,
        recoveryAttempt: Int = 0,
        isBridgeRunning: () -> Boolean?,
        isProtectMonitorRunning: () -> Boolean = { true },
        isApiHealthy: () -> Boolean = { true },
        isApiPortReachable: () -> Boolean = { true },
        monotonicMillis: () -> Long = { System.nanoTime() / 1_000_000L },
        apiFailureGraceMillis: Long = 30_000L,
        sleep: (Long) -> Unit = Thread::sleep
    ): CoreLivenessOutcome {
        val recoveryBudget = CoreRecoveryBudget(recoveryAttempt)
        var consecutiveApiFailures = 0
        var firstApiFailure: Long? = null
        var lastObservation: Long? = null
        while (startToken == currentGeneration() && isRunning()) {
            val bridgeRunning = isBridgeRunning()
            if (startToken != currentGeneration()) {
                return CoreLivenessOutcome(false, recoveryBudget.attempt)
            }
            if (bridgeRunning == false) break
            val protectMonitorRunning = isProtectMonitorRunning()
            if (!protectMonitorRunning) break
            if (startToken != currentGeneration() || !isRunning()) {
                return CoreLivenessOutcome(false, recoveryBudget.attempt)
            }

            val now = monotonicMillis()
            val previous = lastObservation
            if (previous != null && (now < previous || now - previous > 30_000L)) {
                consecutiveApiFailures = 0
                firstApiFailure = null
            }
            lastObservation = now
            val apiHealthy = isApiHealthy()
            recoveryBudget.observeHealth(
                bridgeRunning == true && protectMonitorRunning && apiHealthy,
                monotonicMillis()
            )
            if (apiHealthy) {
                consecutiveApiFailures = 0
                firstApiFailure = null
            } else {
                if (firstApiFailure == null) firstApiFailure = now
                consecutiveApiFailures++
                // Only local API evidence is considered here, never public
                // website reachability. A live bridge gets a bounded grace window.
                if (consecutiveApiFailures >= MAX_CONSECUTIVE_API_FAILURES &&
                    now - firstApiFailure!! >= apiFailureGraceMillis) {
                    if (!isApiPortReachable()) break
                    if (consecutiveApiFailures >= MAX_CONSECUTIVE_API_FAILURES + 1) break
                }
            }
            if (startToken != currentGeneration() || !isRunning()) {
                return CoreLivenessOutcome(false, recoveryBudget.attempt)
            }
            sleep(POLL_INTERVAL_MILLIS)
        }
        return CoreLivenessOutcome(
            startToken == currentGeneration() && isRunning(),
            recoveryBudget.attempt
        )
    }
}
