package com.ssrvpn.android

internal object CoreLivenessMonitor {
    fun waitForUnexpectedExit(
        startToken: Long,
        currentGeneration: () -> Long,
        isRunning: () -> Boolean,
        isBridgeRunning: () -> Boolean
    ): Boolean {
        while (startToken == currentGeneration() && isRunning()) {
            val bridgeRunning = isBridgeRunning()
            if (startToken != currentGeneration()) return false
            if (!bridgeRunning) break
            Thread.sleep(3000)
        }
        return startToken == currentGeneration() && isRunning()
    }
}
