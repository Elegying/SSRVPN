package com.ssrvpn.android

import android.util.Log
import java.util.concurrent.TimeUnit

internal object VpnRuntimeHealth {
    private const val TAG = "SsrvpnVpn"
    private const val API_TIMEOUT_MILLIS = 2_000L

    fun hasProtectMonitor(thread: Thread?): Boolean {
        val healthy = thread?.isAlive == true
        if (!healthy) Log.e(TAG, "VPN protect monitor is not running")
        return healthy
    }

    fun isApiHealthy(port: Int, secret: String): Boolean {
        val startedAt = System.nanoTime()
        val deadline = System.nanoTime() +
            TimeUnit.MILLISECONDS.toNanos(API_TIMEOUT_MILLIS)
        val readiness = MihomoApiHealthProbe.runtimeReadiness(port, secret, deadline)
        val healthy = readiness == MihomoApiReadiness.READY
        if (!healthy) {
            val elapsedMillis = ((System.nanoTime() - startedAt) / 1_000_000L)
                .coerceAtLeast(0L)
            Log.w(
                TAG,
                "event=vpn_runtime_probe endpoint=local_api status=failed " +
                    "elapsedMs=$elapsedMillis cause=${readiness.logValue}"
            )
        }
        return healthy
    }
}
