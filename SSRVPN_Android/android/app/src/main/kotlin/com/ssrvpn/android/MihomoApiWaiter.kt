package com.ssrvpn.android

import java.util.concurrent.TimeUnit

internal class MihomoApiWaiter(
    private val probe: (Int, String, Long) -> Boolean = MihomoApiHealthProbe::isHealthy
) {
    fun waitUntilHealthy(
        apiPort: Int,
        apiSecret: String,
        deadlineNanos: Long,
        pollIntervalMillis: Long,
        ensureCurrent: () -> Unit
    ): Boolean {
        while (System.nanoTime() < deadlineNanos) {
            ensureCurrent()
            val healthy = probe(apiPort, apiSecret, deadlineNanos)
            ensureCurrent()
            if (healthy) return true

            val remainingNanos = (deadlineNanos - System.nanoTime()).coerceAtLeast(0L)
            Thread.sleep(
                minOf(
                    pollIntervalMillis,
                    TimeUnit.NANOSECONDS.toMillis(remainingNanos)
                )
            )
        }
        return false
    }
}
