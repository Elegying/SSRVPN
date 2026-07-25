package com.ssrvpn.android

import java.net.InetSocketAddress
import java.net.Socket

internal object CorePortReleaseVerifier {
    // Bridge.stop can return before its listener closes. Allow five seconds
    // before treating the detached TUN/core shutdown as genuinely stuck.
    private const val DEFAULT_RELEASE_ATTEMPTS = 51
    private const val DEFAULT_RETRY_DELAY_MILLIS = 100L

    fun waitUntilReleased(
        port: Int,
        attempts: Int = DEFAULT_RELEASE_ATTEMPTS,
        retryDelayMillis: Long = DEFAULT_RETRY_DELAY_MILLIS,
        canConnect: (Int) -> Boolean = ::canConnect,
    ): Boolean {
        if (port !in 1..65535) return true
        repeat(attempts.coerceAtLeast(1)) { attempt ->
            if (!canConnect(port)) return true
            if (attempt + 1 < attempts && retryDelayMillis > 0) {
                try {
                    Thread.sleep(retryDelayMillis)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return false
                }
            }
        }
        return false
    }

    private fun canConnect(port: Int): Boolean =
        try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress("127.0.0.1", port), 100)
            }
            true
        } catch (_: Exception) {
            false
        }

    /** 端口是否仍有人监听（与 [waitUntilReleased] 语义相反）。 */
    fun isPortListening(port: Int): Boolean = canConnect(port)
}
