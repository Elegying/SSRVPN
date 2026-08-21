package com.ssrvpn.android

import android.util.Log
import java.io.IOException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.net.URL
import java.util.concurrent.Callable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SSLException

/**
 * Verifies the same Android VPN data path used by browsers and other apps.
 *
 * The SSRVPN package must remain inside the VPN for this probe to be
 * meaningful. Native Mihomo outbound sockets are kept outside the VPN one by
 * one through VpnService.protect(), rather than bypassing this whole package.
 */
internal object VpnDataPlaneProbe {
    private const val TAG = "SsrvpnVpn"
    private val endpoints = listOf(
        "https://www.gstatic.com/generate_204",
        "https://www.youtube.com/generate_204",
        "https://cp.cloudflare.com/generate_204"
    )
    private const val maxBoundedAttempts = 3
    private const val requestTimeoutMillis = 2_000
    private const val startupRetryDelayMillis = 200L
    private val startupProbeCompletion = AtomicReference<CountDownLatch?>()

    // HttpURLConnection timeouts do not cover DNS resolution. This remains
    // the absolute outer watchdog budget for all attempts and retry delays.
    internal const val MAX_STARTUP_DURATION_MILLIS =
        maxBoundedAttempts * requestTimeoutMillis * 2L +
            (maxBoundedAttempts - 1) * startupRetryDelayMillis

    internal data class AttemptDiagnostic(
        val endpointCategory: String,
        val attempt: Int,
        val totalAttempts: Int,
        val status: Int?,
        val elapsedMillis: Long,
        val cause: String
    )

    internal enum class StartupOutcome(
        val logValue: String,
        val failureMessage: String?
    ) {
        HEALTHY("healthy", null),
        UNREACHABLE(
            "unreachable",
            "VPN 数据通道不可用，请切换节点或重试"
        ),
        WATCHDOG_TIMEOUT(
            "watchdog_timeout",
            "VPN 联网检查超时，请稍后重试；若持续出现请重启应用"
        ),
        PREVIOUS_PROBE_STILL_RUNNING(
            "previous_probe_still_running",
            "上次 VPN 联网检查仍在结束，请稍后重试；若持续出现请重启应用"
        ),
        PROTECT_MONITOR_UNAVAILABLE(
            "protect_monitor_unavailable",
            "VPN 网络保护服务异常，请重新连接"
        )
    }

    private data class ProbeResult(
        val reachable: Boolean,
        val diagnostics: List<AttemptDiagnostic>
    )

    fun startupOutcome(
        protectThread: Thread?,
        beforeAttempt: () -> Unit
    ): StartupOutcome {
        val reachability = probeReachability(
            retryDelayMillis = startupRetryDelayMillis,
            beforeAttempt = beforeAttempt,
            recordAttempt = ::logAttempt
        )
        val outcome = if (
            reachability == StartupOutcome.HEALTHY &&
            !VpnRuntimeHealth.hasProtectMonitor(protectThread)
        ) {
            StartupOutcome.PROTECT_MONITOR_UNAVAILABLE
        } else {
            reachability
        }
        Log.i(TAG, "event=vpn_data_plane_startup outcome=${outcome.logValue}")
        return outcome
    }

    fun isReachable(
        endpoints: List<String> = this.endpoints,
        maxAttempts: Int = maxBoundedAttempts,
        retryDelayMillis: Long = 0,
        totalBudgetMillis: Long = MAX_STARTUP_DURATION_MILLIS,
        beforeAttempt: () -> Unit = {},
        fetchStatus: (String) -> Int? = ::fetchHttpStatus,
        recordAttempt: (AttemptDiagnostic) -> Unit = {}
    ): Boolean = probeReachability(
        endpoints,
        maxAttempts,
        retryDelayMillis,
        totalBudgetMillis,
        beforeAttempt,
        fetchStatus,
        recordAttempt
    ) == StartupOutcome.HEALTHY

    internal fun probeReachability(
        endpoints: List<String> = this.endpoints,
        maxAttempts: Int = maxBoundedAttempts,
        retryDelayMillis: Long = 0,
        totalBudgetMillis: Long = MAX_STARTUP_DURATION_MILLIS,
        beforeAttempt: () -> Unit = {},
        fetchStatus: (String) -> Int? = ::fetchHttpStatus,
        recordAttempt: (AttemptDiagnostic) -> Unit = {}
    ): StartupOutcome {
        if (endpoints.isEmpty() || totalBudgetMillis <= 0L) {
            return StartupOutcome.UNREACHABLE
        }
        val deadlineNanos = System.nanoTime() +
            TimeUnit.MILLISECONDS.toNanos(totalBudgetMillis)
        val completion = acquireProbeSlot(deadlineNanos, beforeAttempt)
            ?: return StartupOutcome.PREVIOUS_PROBE_STILL_RUNNING
        val attempts = maxAttempts.coerceIn(1, maxBoundedAttempts)
        val active = AtomicBoolean(true)
        val task = FutureTask(
            Callable {
                runAttempts(
                    endpoints,
                    attempts,
                    retryDelayMillis,
                    active::get,
                    beforeAttempt,
                    fetchStatus
                )
            }
        )
        try {
            Thread({
                try {
                    task.run()
                } finally {
                    releaseProbeSlot(completion)
                }
            }, "SSRVPN-data-plane-startup-probe").apply {
                isDaemon = true
                start()
            }
        } catch (error: Throwable) {
            releaseProbeSlot(completion)
            throw error
        }
        val remainingNanos = deadlineNanos - System.nanoTime()
        if (remainingNanos <= 0L) {
            active.set(false)
            task.cancel(true)
            return StartupOutcome.WATCHDOG_TIMEOUT
        }
        val result = try {
            task.get(remainingNanos, TimeUnit.NANOSECONDS)
        } catch (_: TimeoutException) {
            active.set(false)
            task.cancel(true)
            return StartupOutcome.WATCHDOG_TIMEOUT
        } catch (error: InterruptedException) {
            active.set(false)
            task.cancel(true)
            Thread.currentThread().interrupt()
            throw error
        } catch (error: ExecutionException) {
            throw error.cause ?: error
        }
        result.diagnostics.forEach { diagnostic ->
            try {
                recordAttempt(diagnostic)
            } catch (_: Exception) {
                // Diagnostics must never weaken or abort the startup gate.
            }
        }
        return if (result.reachable) {
            StartupOutcome.HEALTHY
        } else {
            StartupOutcome.UNREACHABLE
        }
    }

    private fun acquireProbeSlot(
        deadlineNanos: Long,
        beforeAttempt: () -> Unit
    ): CountDownLatch? {
        while (true) {
            beforeAttempt()
            val remainingNanos = deadlineNanos - System.nanoTime()
            if (remainingNanos <= 0L) return null
            val completion = CountDownLatch(1)
            if (startupProbeCompletion.compareAndSet(null, completion)) {
                return completion
            }
            val inFlight = startupProbeCompletion.get() ?: continue
            if (!inFlight.await(remainingNanos, TimeUnit.NANOSECONDS)) return null
        }
    }

    private fun releaseProbeSlot(completion: CountDownLatch) {
        startupProbeCompletion.compareAndSet(completion, null)
        completion.countDown()
    }

    private fun runAttempts(
        endpoints: List<String>,
        attempts: Int,
        retryDelayMillis: Long,
        isActive: () -> Boolean,
        beforeAttempt: () -> Unit,
        fetchStatus: (String) -> Int?
    ): ProbeResult {
        val diagnostics = mutableListOf<AttemptDiagnostic>()
        repeat(attempts) { index ->
            if (!isActive()) return ProbeResult(false, diagnostics)
            beforeAttempt()
            if (!isActive()) return ProbeResult(false, diagnostics)
            val endpoint = endpoints[index % endpoints.size]
            val startedAt = System.nanoTime()
            var status: Int? = null
            var failure: Exception? = null
            try {
                status = fetchStatus(endpoint)
            } catch (error: Exception) {
                failure = error
            }
            if (!isActive()) return ProbeResult(false, diagnostics)
            diagnostics += AttemptDiagnostic(
                endpointCategory = endpointCategory(endpoint),
                attempt = index + 1,
                totalAttempts = attempts,
                status = status,
                elapsedMillis = ((System.nanoTime() - startedAt) / 1_000_000L)
                    .coerceAtLeast(0L),
                cause = attemptCause(status, failure)
            )
            if (status == HttpURLConnection.HTTP_NO_CONTENT) {
                return ProbeResult(true, diagnostics)
            }
            if (index + 1 < attempts && retryDelayMillis > 0) {
                Thread.sleep(retryDelayMillis)
            }
        }
        return ProbeResult(false, diagnostics)
    }

    private fun fetchHttpStatus(endpoint: String): Int? {
        val connection = URL(endpoint).openConnection() as HttpURLConnection
        return try {
            connection.connectTimeout = requestTimeoutMillis
            connection.readTimeout = requestTimeoutMillis
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.setRequestProperty("Cache-Control", "no-cache")
            connection.responseCode
        } finally {
            connection.disconnect()
        }
    }

    private fun endpointCategory(endpoint: String): String = when {
        endpoint.startsWith("https://www.gstatic.com/") -> "google"
        endpoint.startsWith("https://www.youtube.com/") -> "youtube"
        endpoint.startsWith("https://cp.cloudflare.com/") -> "cloudflare"
        else -> "other"
    }

    private fun attemptCause(status: Int?, failure: Throwable?): String {
        if (failure == null) {
            return when (status) {
                HttpURLConnection.HTTP_NO_CONTENT -> "none"
                null -> "no_response"
                else -> "http_status"
            }
        }
        var current: Throwable? = failure
        while (current != null) {
            when (current) {
                is UnknownHostException -> return "dns"
                is SocketTimeoutException -> return "timeout"
                is SSLException -> return "tls"
                is IOException -> return "io"
            }
            current = current.cause
        }
        return "unexpected"
    }

    private fun logAttempt(diagnostic: AttemptDiagnostic) {
        Log.i(
            TAG,
            "event=vpn_data_plane_probe " +
                "endpoint=${diagnostic.endpointCategory} " +
                "attempt=${diagnostic.attempt}/${diagnostic.totalAttempts} " +
                "status=${diagnostic.status ?: "none"} " +
                "elapsedMs=${diagnostic.elapsedMillis} " +
                "cause=${diagnostic.cause}"
        )
    }
}
