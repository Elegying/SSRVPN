package com.ssrvpn.android

internal data class CoreLivenessOutcome(
    val unexpectedExit: Boolean,
    val recoveryAttempt: Int
)

internal object CoreLivenessMonitor {
    private const val MAX_CONSECUTIVE_API_FAILURES = 3

    // A short socket sample is not proof of a dead core. Both the API
    // failure window and repeated port misses must elapse before recovery.
    private const val PORT_MISSES_BEFORE_RESTART = 2
    private const val MAX_OBSERVATION_GAP_MILLIS = 10_000L
    private const val POLL_INTERVAL_MILLIS = 3_000L

    // Keep observation outside the generation lock; only its lifecycle effects
    // belong to the originating session's atomic publication boundary.
    fun observeSession(
        startToken: Long,
        gate: StartGenerationGate,
        waitForExit: () -> CoreLivenessOutcome,
        onUnexpectedExit: (CoreLivenessOutcome) -> Unit,
        onFailure: (Exception) -> Unit
    ) {
        try {
            val outcome = waitForExit()
            if (outcome.unexpectedExit) {
                gate.runIfCurrent(startToken) { onUnexpectedExit(outcome) }
            }
        } catch (error: Exception) {
            gate.runIfCurrent(startToken) { onFailure(error) }
        }
    }

    fun waitForUnexpectedExit(
        startToken: Long,
        currentGeneration: () -> Long,
        isRunning: () -> Boolean,
        recoveryAttempt: Int = 0,
        isBridgeRunning: () -> Boolean?,
        isProtectMonitorRunning: () -> Boolean = { true },
        isApiHealthy: () -> Boolean = { true },
        isApiPortReachable: () -> Boolean? = { true },
        monotonicMillis: () -> Long = { System.nanoTime() / 1_000_000L },
        apiFailureGraceMillis: Long = 15_000L,
        sleep: (Long) -> Unit = Thread::sleep
    ): CoreLivenessOutcome {
        val recoveryBudget = CoreRecoveryBudget(recoveryAttempt)
        var consecutiveApiFailures = 0
        var consecutivePortMisses = 0
        var firstApiFailure: Long? = null
        var lastObservation: Long? = null
        while (startToken == currentGeneration() && isRunning()) {
            val observationStart = monotonicMillis()
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
            if ((previous != null &&
                    (observationStart < previous ||
                        observationStart - previous > MAX_OBSERVATION_GAP_MILLIS)) ||
                now < observationStart || now - observationStart > MAX_OBSERVATION_GAP_MILLIS
            ) {
                // Sleep and scheduling gaps are not evidence of API failure.
                consecutiveApiFailures = 0
                consecutivePortMisses = 0
                firstApiFailure = null
            }
            val apiHealthy = isApiHealthy()
            val apiFinished = monotonicMillis()
            if (apiFinished < now || apiFinished - now > MAX_OBSERVATION_GAP_MILLIS) {
                // A suspension inside the probe is not continuous failure evidence.
                consecutiveApiFailures = 0
                consecutivePortMisses = 0
                firstApiFailure = null
                recoveryBudget.observeHealth(null, apiFinished)
                lastObservation = apiFinished
                sleep(POLL_INTERVAL_MILLIS)
                continue
            }
            recoveryBudget.observeHealth(
                bridgeRunning == true && protectMonitorRunning && apiHealthy,
                monotonicMillis()
            )
            if (apiHealthy) {
                consecutiveApiFailures = 0
                consecutivePortMisses = 0
                firstApiFailure = null
            } else {
                if (firstApiFailure == null) firstApiFailure = now
                consecutiveApiFailures++
                // Only local API evidence is considered here, never public
                // website reachability. Two independent conditions can end the
                // wait, both gated on repeated failures:
                if (consecutiveApiFailures >= MAX_CONSECUTIVE_API_FAILURES) {
                    val portStarted = monotonicMillis()
                    val portReachable = isApiPortReachable()
                    val portFinished = monotonicMillis()
                    if (portStarted < apiFinished ||
                        portStarted - apiFinished > MAX_OBSERVATION_GAP_MILLIS ||
                        portFinished < portStarted ||
                        portFinished - portStarted > MAX_OBSERVATION_GAP_MILLIS) {
                        consecutiveApiFailures = 0
                        consecutivePortMisses = 0
                        firstApiFailure = null
                        recoveryBudget.observeHealth(null, portFinished)
                        lastObservation = portFinished
                        sleep(POLL_INTERVAL_MILLIS)
                        continue
                    }
                    when (portReachable) {
                        false -> {
                            consecutivePortMisses++
                            if (consecutivePortMisses >= PORT_MISSES_BEFORE_RESTART &&
                                now - firstApiFailure!! >= apiFailureGraceMillis) break
                        }
                        true -> {
                            consecutivePortMisses = 0
                            if (now - firstApiFailure!! >= apiFailureGraceMillis) break
                        }
                        null -> {
                            // Timeouts and local socket errors are inconclusive.
                            // A persistent API stall still has a bounded recovery.
                            consecutivePortMisses = 0
                            if (now - firstApiFailure!! >= apiFailureGraceMillis * 2) break
                        }
                    }
                }
            }
            if (startToken != currentGeneration() || !isRunning()) {
                return CoreLivenessOutcome(false, recoveryBudget.attempt)
            }
            lastObservation = monotonicMillis()
            sleep(POLL_INTERVAL_MILLIS)
        }
        return CoreLivenessOutcome(
            startToken == currentGeneration() && isRunning(),
            recoveryBudget.attempt
        )
    }
}
