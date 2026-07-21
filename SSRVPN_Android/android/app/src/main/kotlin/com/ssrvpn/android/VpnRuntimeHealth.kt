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
        val deadline = System.nanoTime() +
            TimeUnit.MILLISECONDS.toNanos(API_TIMEOUT_MILLIS)
        val healthy = MihomoApiHealthProbe.isHealthy(port, secret, deadline)
        if (!healthy) Log.w(TAG, "Mihomo local API runtime health check failed")
        return healthy
    }
}
