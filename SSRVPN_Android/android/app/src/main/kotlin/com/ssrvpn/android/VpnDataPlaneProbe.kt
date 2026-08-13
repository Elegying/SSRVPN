package com.ssrvpn.android

import java.net.HttpURLConnection
import java.net.URL

/**
 * Verifies the same Android VPN data path used by browsers and other apps.
 *
 * The SSRVPN package must remain inside the VPN for this probe to be
 * meaningful. Native Mihomo outbound sockets are kept outside the VPN one by
 * one through VpnService.protect(), rather than bypassing this whole package.
 */
internal object VpnDataPlaneProbe {
    private val endpoints = listOf(
        "https://www.gstatic.com/generate_204",
        "https://www.youtube.com/generate_204",
        "https://cp.cloudflare.com/generate_204"
    )
    private const val maxBoundedAttempts = 3
    private const val requestTimeoutMillis = 2_000

    fun isStartupHealthy(protectThread: Thread?, beforeAttempt: () -> Unit): Boolean =
        isReachable(retryDelayMillis = 200, beforeAttempt = beforeAttempt) &&
            VpnRuntimeHealth.hasProtectMonitor(protectThread)

    fun isReachable(
        endpoints: List<String> = this.endpoints,
        maxAttempts: Int = maxBoundedAttempts,
        retryDelayMillis: Long = 0,
        beforeAttempt: () -> Unit = {},
        fetchStatus: (String) -> Int? = ::fetchHttpStatus
    ): Boolean {
        if (endpoints.isEmpty()) return false
        val attempts = maxAttempts.coerceIn(1, maxBoundedAttempts)
        repeat(attempts) { index ->
            beforeAttempt()
            val endpoint = endpoints[index % endpoints.size]
            if (fetchStatus(endpoint) == HttpURLConnection.HTTP_NO_CONTENT) {
                return true
            }
            if (index + 1 < attempts && retryDelayMillis > 0) {
                Thread.sleep(retryDelayMillis)
            }
        }
        return false
    }

    private fun fetchHttpStatus(endpoint: String): Int? {
        val connection = try {
            URL(endpoint).openConnection() as HttpURLConnection
        } catch (_: Exception) {
            return null
        }
        return try {
            connection.connectTimeout = requestTimeoutMillis
            connection.readTimeout = requestTimeoutMillis
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.setRequestProperty("Cache-Control", "no-cache")
            connection.responseCode
        } catch (_: Exception) {
            null
        } finally {
            connection.disconnect()
        }
    }
}
