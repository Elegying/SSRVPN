package com.ssrvpn.android

import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit

internal object MihomoApiHealthProbe {
    private const val MAX_RESPONSE_CHARS = 4 * 1024
    private val metaField = Regex("""[\"]meta[\"]\s*:\s*(?:true|false)""")
    private val versionField = Regex("""[\"]version[\"]\s*:\s*[\"][^\"\r\n]{1,128}[\"]""")
    private val deadlineScheduler =
        ScheduledThreadPoolExecutor(1) { runnable ->
            Thread(runnable, "mihomo-api-health-deadline").apply { isDaemon = true }
        }.apply {
            removeOnCancelPolicy = true
        }

    fun isHealthy(port: Int, apiSecret: String, deadlineNanos: Long): Boolean {
        if (port !in 1..65535 || remainingTimeoutMillis(deadlineNanos) == null) return false

        var connection: HttpURLConnection? = null
        var deadlineGuard: ScheduledFuture<*>? = null
        return try {
            val apiConnection =
                (URL("http://127.0.0.1:$port/version").openConnection() as HttpURLConnection)
                    .also { connection = it }
            apiConnection.requestMethod = "GET"
            apiConnection.connectTimeout = remainingTimeoutMillis(deadlineNanos) ?: return false
            apiConnection.readTimeout = remainingTimeoutMillis(deadlineNanos) ?: return false
            apiConnection.instanceFollowRedirects = false
            apiConnection.useCaches = false
            apiConnection.setRequestProperty("Accept", "application/json")
            if (apiSecret.isNotBlank()) {
                apiConnection.setRequestProperty("Authorization", "Bearer $apiSecret")
            }
            val guardDelayNanos = deadlineNanos - System.nanoTime()
            if (guardDelayNanos <= 0L) return false
            deadlineGuard = deadlineScheduler.schedule(
                { apiConnection.disconnect() },
                guardDelayNanos,
                TimeUnit.NANOSECONDS
            )

            apiConnection.connect()
            apiConnection.readTimeout = remainingTimeoutMillis(deadlineNanos) ?: return false
            if (apiConnection.responseCode != HttpURLConnection.HTTP_OK) return false
            val mediaType = apiConnection.contentType?.substringBefore(';')?.trim()
            if (!mediaType.equals("application/json", ignoreCase = true)) return false

            apiConnection.readTimeout = remainingTimeoutMillis(deadlineNanos) ?: return false
            val body = apiConnection.inputStream.bufferedReader(Charsets.UTF_8).use { reader ->
                val chars = CharArray(MAX_RESPONSE_CHARS + 1)
                var count = 0
                while (count < chars.size) {
                    apiConnection.readTimeout = remainingTimeoutMillis(deadlineNanos) ?: return false
                    val read = reader.read(chars, count, chars.size - count)
                    if (read < 0) break
                    count += read
                }
                if (count > MAX_RESPONSE_CHARS) null else String(chars, 0, count)
            } ?: return false
            val json = body.trim()
            remainingTimeoutMillis(deadlineNanos) != null &&
                json.startsWith('{') &&
                json.endsWith('}') &&
                metaField.containsMatchIn(json) &&
                versionField.containsMatchIn(json)
        } catch (_: Exception) {
            false
        } finally {
            deadlineGuard?.cancel(false)
            connection?.disconnect()
        }
    }

    private fun remainingTimeoutMillis(deadlineNanos: Long): Int? {
        val remainingNanos = deadlineNanos - System.nanoTime()
        if (remainingNanos <= 0L) return null
        val remainingMillis = TimeUnit.NANOSECONDS.toMillis(remainingNanos)
        if (remainingMillis <= 0L) return null
        return remainingMillis
            .coerceAtMost(Int.MAX_VALUE.toLong())
            .toInt()
    }
}
