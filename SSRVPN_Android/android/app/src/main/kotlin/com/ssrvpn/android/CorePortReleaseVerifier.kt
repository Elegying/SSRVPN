package com.ssrvpn.android

import java.net.InetSocketAddress
import java.net.Socket

internal object CorePortReleaseVerifier {
    fun waitUntilReleased(
        port: Int,
        attempts: Int = 6,
        retryDelayMillis: Long = 100,
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
}
