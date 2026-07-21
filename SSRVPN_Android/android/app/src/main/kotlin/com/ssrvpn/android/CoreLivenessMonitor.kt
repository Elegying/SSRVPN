package com.ssrvpn.android

internal object CoreLivenessMonitor {
    private const val MAX_CONSECUTIVE_API_FAILURES = 3
    private const val POLL_INTERVAL_MILLIS = 3_000L

    fun waitForUnexpectedExit(
        startToken: Long,
        currentGeneration: () -> Long,
        isRunning: () -> Boolean,
        isBridgeRunning: () -> Boolean,
        isProtectMonitorRunning: () -> Boolean = { true },
        isApiHealthy: () -> Boolean = { true },
        sleep: (Long) -> Unit = Thread::sleep
    ): Boolean {
        var consecutiveApiFailures = 0
        while (startToken == currentGeneration() && isRunning()) {
            val bridgeRunning = isBridgeRunning()
            if (startToken != currentGeneration()) return false
            if (!bridgeRunning) break
            if (!isProtectMonitorRunning()) break
            if (startToken != currentGeneration() || !isRunning()) return false

            if (isApiHealthy()) {
                consecutiveApiFailures = 0
            } else {
                consecutiveApiFailures++
                if (consecutiveApiFailures >= MAX_CONSECUTIVE_API_FAILURES) break
            }
            if (startToken != currentGeneration() || !isRunning()) return false
            sleep(POLL_INTERVAL_MILLIS)
        }
        return startToken == currentGeneration() && isRunning()
    }
}
