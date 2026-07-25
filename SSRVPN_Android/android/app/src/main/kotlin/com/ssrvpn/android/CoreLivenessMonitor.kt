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
        isApiPortReachable: () -> Boolean = { true },
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
                // API 健康检查连续失败后，用 TCP 端口探测做二次确认：
                // 端口也不可达 → 核心已死亡，立即退出；
                // 端口可达但 API 不通 → 僵尸 socket，同样退出。
                if (consecutiveApiFailures >= MAX_CONSECUTIVE_API_FAILURES) {
                    if (!isApiPortReachable()) break
                    // 端口可达但 API 无响应，视为核心僵死
                    if (consecutiveApiFailures >= MAX_CONSECUTIVE_API_FAILURES + 1) break
                }
            }
            if (startToken != currentGeneration() || !isRunning()) return false
            sleep(POLL_INTERVAL_MILLIS)
        }
        return startToken == currentGeneration() && isRunning()
    }
}
