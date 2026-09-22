package com.ssrvpn.android

internal data class CoreLivenessOutcome(
    val unexpectedExit: Boolean,
    val recoveryAttempt: Int
)

internal object CoreLivenessMonitor {
    private const val MAX_CONSECUTIVE_API_FAILURES = 3

    // The port probe is itself a single 100 ms sample (see
    // CorePortReleaseVerifier.canConnect, socket.connect(..., 100)), so a
    // scheduling hiccup or a doze wake-up can produce a false timeout. A single
    // miss is therefore not enough to declare the core dead; two consecutive
    // misses are required. Because the probe only runs once the API failure
    // threshold is already reached, the hard-fail path now costs about four
    // polls (~9s) instead of three (~6s) before restarting.
    private const val PORT_MISSES_BEFORE_RESTART = 2
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
        apiFailureGraceMillis: Long = 15_000L,
        sleep: (Long) -> Unit = Thread::sleep
    ): CoreLivenessOutcome {
        val recoveryBudget = CoreRecoveryBudget(recoveryAttempt)
        var consecutiveApiFailures = 0
        var consecutivePortMisses = 0
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
                // A device suspend or a clock rollback makes the observation
                // window non-contiguous, so the failure streak starts over.
                //
                // The 30_000L here is now exactly twice the default
                // apiFailureGraceMillis (15_000L). That 2x is a side effect of
                // narrowing the grace, not a chosen value: both constants were
                // 30_000L before. It means a 15-30s sleep with a genuinely
                // failing API skips this reset, so the first observation after
                // wake can already satisfy the grace and restart. That is
                // acceptable -- the API did fail for the whole window, and a
                // core that recovered during the sleep reports healthy and
                // resets the streak instead. But the two constants are
                // independent, so changing either one alone changes which
                // sleep windows can trip a restart.
                consecutiveApiFailures = 0
                consecutivePortMisses = 0
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
                consecutivePortMisses = 0
                firstApiFailure = null
            } else {
                if (firstApiFailure == null) firstApiFailure = now
                consecutiveApiFailures++
                // Only local API evidence is considered here, never public
                // website reachability. Two independent conditions can end the
                // wait, both gated on repeated failures:
                if (consecutiveApiFailures >= MAX_CONSECUTIVE_API_FAILURES) {
                    if (!isApiPortReachable()) {
                        // A closed API port is the hard evidence that the core
                        // process is already gone. The probe is only a single
                        // 100 ms sample, so one miss can be a transient
                        // scheduling hiccup; require two in a row before
                        // treating the port as genuinely dead.
                        consecutivePortMisses++
                        if (consecutivePortMisses >= PORT_MISSES_BEFORE_RESTART) break
                    } else {
                        // The core still owns the port but is not answering.
                        // Treat it as a bounded stall so a transient freeze
                        // does not cost a full restart, yet do not wait out the
                        // old 30s window.
                        consecutivePortMisses = 0
                        if (now - firstApiFailure!! >= apiFailureGraceMillis) break
                    }
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
