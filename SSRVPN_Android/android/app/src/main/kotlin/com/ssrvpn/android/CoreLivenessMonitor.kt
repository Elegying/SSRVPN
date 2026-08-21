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
        sleep: (Long) -> Unit = Thread::sleep
    ): CoreLivenessOutcome {
        val recoveryBudget = CoreRecoveryBudget(recoveryAttempt)
        var consecutiveApiFailures = 0
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

            val apiHealthy = isApiHealthy()
            recoveryBudget.observeHealth(
                bridgeRunning == true && protectMonitorRunning && apiHealthy,
                monotonicMillis()
            )
            if (apiHealthy) {
                consecutiveApiFailures = 0
            } else {
                consecutiveApiFailures++
                // API 健康检查连续失败后，用 TCP 端口探测做二次确认：
                // 端口也不可达 → 核心已死亡，立即退出；
                // 端口可达但 API 不通 → 僵尸 socket，同样退出。
                if (consecutiveApiFailures >= MAX_CONSECUTIVE_API_FAILURES) {
                    if (!isApiPortReachable()) break
                    // 端口可达但 API 无响应，视为核心僵死
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
