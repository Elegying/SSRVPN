package com.ssrvpn.android

import java.io.IOException
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit

internal enum class MihomoApiReadiness(val logValue: String) {
    READY("ready"),
    PENDING("pending"),
    PORT_CONFLICT("port_conflict"),
    AUTH_REJECTED("auth_rejected"),
    TUN_DISABLED("tun_disabled"),
    TIMEOUT("timeout")
}

internal object MihomoApiHealthProbe {
    private const val MAX_VERSION_RESPONSE_BYTES = 4 * 1024
    private const val MAX_CONFIG_RESPONSE_BYTES = 256 * 1024
    private val metaField = Regex("""["]meta["]\s*:\s*(?:true|false)""")
    private val versionField = Regex("""["]version["]\s*:\s*["][^\"\r\n]{1,128}["]""")
    private val deadlineScheduler =
        ScheduledThreadPoolExecutor(1) { runnable ->
            Thread(runnable, "mihomo-api-health-deadline").apply { isDaemon = true }
        }.apply {
            removeOnCancelPolicy = true
        }

    fun runtimeReadiness(
        port: Int,
        apiSecret: String,
        deadlineNanos: Long
    ): MihomoApiReadiness = versionReadiness(port, apiSecret, deadlineNanos)

    fun isHealthy(port: Int, apiSecret: String, deadlineNanos: Long): Boolean =
        runtimeReadiness(port, apiSecret, deadlineNanos) == MihomoApiReadiness.READY

    fun readiness(port: Int, apiSecret: String, deadlineNanos: Long): MihomoApiReadiness {
        val versionState = versionReadiness(port, apiSecret, deadlineNanos)
        if (versionState != MihomoApiReadiness.READY) return versionState

        val configResponse = requestJson(
            port = port,
            path = "/configs",
            apiSecret = apiSecret,
            deadlineNanos = deadlineNanos,
            maxResponseBytes = MAX_CONFIG_RESPONSE_BYTES
        )
        when (configResponse.status) {
            HttpJsonStatus.TIMEOUT -> return MihomoApiReadiness.TIMEOUT
            HttpJsonStatus.AUTH_REJECTED -> return MihomoApiReadiness.AUTH_REJECTED
            HttpJsonStatus.UNAVAILABLE,
            HttpJsonStatus.INVALID -> return MihomoApiReadiness.PENDING
            HttpJsonStatus.SUCCESS -> Unit
        }
        val configJson = configResponse.body.orEmpty().trim()
        if (!configJson.startsWith('{') || !configJson.endsWith('}')) {
            return MihomoApiReadiness.PENDING
        }
        return when (configJson.directNestedBoolean("tun", "enable")) {
            true -> MihomoApiReadiness.READY
            false -> MihomoApiReadiness.TUN_DISABLED
            else -> MihomoApiReadiness.PENDING
        }
    }

    private fun versionReadiness(
        port: Int,
        apiSecret: String,
        deadlineNanos: Long
    ): MihomoApiReadiness {
        if (remainingTimeoutMillis(deadlineNanos) == null) return MihomoApiReadiness.TIMEOUT
        if (port !in 1..65535) return MihomoApiReadiness.PORT_CONFLICT

        val versionResponse = requestJson(
            port = port,
            path = "/version",
            apiSecret = apiSecret,
            deadlineNanos = deadlineNanos,
            maxResponseBytes = MAX_VERSION_RESPONSE_BYTES
        )
        when (versionResponse.status) {
            HttpJsonStatus.TIMEOUT -> return MihomoApiReadiness.TIMEOUT
            HttpJsonStatus.UNAVAILABLE -> return MihomoApiReadiness.PENDING
            HttpJsonStatus.AUTH_REJECTED -> return MihomoApiReadiness.AUTH_REJECTED
            HttpJsonStatus.INVALID -> return MihomoApiReadiness.PORT_CONFLICT
            HttpJsonStatus.SUCCESS -> Unit
        }
        val versionJson = versionResponse.body.orEmpty().trim()
        if (!versionJson.startsWith('{') ||
            !versionJson.endsWith('}') ||
            !metaField.containsMatchIn(versionJson) ||
            !versionField.containsMatchIn(versionJson)
        ) {
            return MihomoApiReadiness.PORT_CONFLICT
        }
        return MihomoApiReadiness.READY
    }

    private fun requestJson(
        port: Int,
        path: String,
        apiSecret: String,
        deadlineNanos: Long,
        maxResponseBytes: Int
    ): HttpJsonResponse {
        var connection: HttpURLConnection? = null
        var deadlineGuard: ScheduledFuture<*>? = null
        return try {
            val apiConnection =
                (URL("http://127.0.0.1:$port$path").openConnection() as HttpURLConnection)
                    .also { connection = it }
            apiConnection.requestMethod = "GET"
            apiConnection.connectTimeout = remainingTimeoutMillis(deadlineNanos)
                ?: return HttpJsonResponse(HttpJsonStatus.TIMEOUT)
            apiConnection.readTimeout = remainingTimeoutMillis(deadlineNanos)
                ?: return HttpJsonResponse(HttpJsonStatus.TIMEOUT)
            apiConnection.instanceFollowRedirects = false
            apiConnection.useCaches = false
            apiConnection.setRequestProperty("Accept", "application/json")
            if (apiSecret.isNotBlank()) {
                apiConnection.setRequestProperty("Authorization", "Bearer $apiSecret")
            }
            val guardDelayNanos = deadlineNanos - System.nanoTime()
            if (guardDelayNanos <= 0L) return HttpJsonResponse(HttpJsonStatus.TIMEOUT)
            deadlineGuard = deadlineScheduler.schedule(
                { apiConnection.disconnect() },
                guardDelayNanos,
                TimeUnit.NANOSECONDS
            )

            apiConnection.connect()
            apiConnection.readTimeout = remainingTimeoutMillis(deadlineNanos)
                ?: return HttpJsonResponse(HttpJsonStatus.TIMEOUT)
            val responseCode = apiConnection.responseCode
            if (responseCode == HttpURLConnection.HTTP_UNAUTHORIZED ||
                responseCode == HttpURLConnection.HTTP_FORBIDDEN
            ) {
                return HttpJsonResponse(HttpJsonStatus.AUTH_REJECTED)
            }
            if (responseCode != HttpURLConnection.HTTP_OK) {
                return HttpJsonResponse(HttpJsonStatus.INVALID)
            }
            val mediaType = apiConnection.contentType?.substringBefore(';')?.trim()
            if (!mediaType.equals("application/json", ignoreCase = true)) {
                return HttpJsonResponse(HttpJsonStatus.INVALID)
            }

            val body = readBoundedBody(
                apiConnection,
                deadlineNanos,
                maxResponseBytes
            ) ?: return HttpJsonResponse(
                if (remainingTimeoutMillis(deadlineNanos) == null) {
                    HttpJsonStatus.TIMEOUT
                } else {
                    HttpJsonStatus.INVALID
                }
            )
            HttpJsonResponse(HttpJsonStatus.SUCCESS, body)
        } catch (_: SocketTimeoutException) {
            HttpJsonResponse(HttpJsonStatus.TIMEOUT)
        } catch (_: ConnectException) {
            HttpJsonResponse(
                if (remainingTimeoutMillis(deadlineNanos) == null) {
                    HttpJsonStatus.TIMEOUT
                } else {
                    HttpJsonStatus.UNAVAILABLE
                }
            )
        } catch (_: IOException) {
            HttpJsonResponse(
                if (remainingTimeoutMillis(deadlineNanos) == null) {
                    HttpJsonStatus.TIMEOUT
                } else {
                    HttpJsonStatus.UNAVAILABLE
                }
            )
        } catch (_: Exception) {
            HttpJsonResponse(HttpJsonStatus.INVALID)
        } finally {
            deadlineGuard?.cancel(false)
            connection?.disconnect()
        }
    }

    private fun readBoundedBody(
        connection: HttpURLConnection,
        deadlineNanos: Long,
        maxResponseBytes: Int
    ): String? = connection.inputStream.use { input ->
        val bytes = ByteArray(maxResponseBytes + 1)
        var count = 0
        while (count < bytes.size) {
            connection.readTimeout = remainingTimeoutMillis(deadlineNanos) ?: return null
            val read = input.read(bytes, count, bytes.size - count)
            if (read < 0) break
            count += read
        }
        if (count > maxResponseBytes) return null
        val declaredLength = connection.contentLengthLong
        if (declaredLength >= 0 && count.toLong() < declaredLength) {
            throw IOException("truncated API response")
        }
        String(bytes, 0, count, Charsets.UTF_8)
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

    private enum class HttpJsonStatus {
        SUCCESS,
        UNAVAILABLE,
        AUTH_REJECTED,
        INVALID,
        TIMEOUT
    }

    private data class HttpJsonResponse(
        val status: HttpJsonStatus,
        val body: String? = null
    )

    private fun String.directNestedBoolean(
        objectField: String,
        booleanField: String
    ): Boolean? {
        val nestedObject = directObjectField(0, length, objectField) ?: return null
        val booleanValue = directObjectField(
            nestedObject.start,
            nestedObject.endExclusive,
            booleanField
        ) ?: return null
        return when (substring(booleanValue.start, booleanValue.endExclusive)) {
            "true" -> true
            "false" -> false
            else -> null
        }
    }

    private fun String.directObjectField(
        objectStart: Int,
        objectEndExclusive: Int,
        fieldName: String
    ): JsonValueRange? {
        // Walk direct object members while structurally skipping nested values.
        var cursor = skipJsonWhitespace(objectStart, objectEndExclusive)
        if (cursor >= objectEndExclusive || this[cursor] != '{') return null
        cursor++
        var matchedValue: JsonValueRange? = null

        while (cursor < objectEndExclusive) {
            cursor = skipJsonWhitespace(cursor, objectEndExclusive)
            if (cursor >= objectEndExclusive) return null
            if (this[cursor] == '}') {
                cursor = skipJsonWhitespace(cursor + 1, objectEndExclusive)
                return matchedValue.takeIf { cursor == objectEndExclusive }
            }
            val keyStart = cursor
            val keyEnd = skipJsonString(keyStart, objectEndExclusive) ?: return null
            val keyMatches = keyEnd - keyStart == fieldName.length + 2 &&
                regionMatches(keyStart + 1, fieldName, 0, fieldName.length)
            cursor = skipJsonWhitespace(keyEnd, objectEndExclusive)
            if (cursor >= objectEndExclusive || this[cursor] != ':') return null
            cursor = skipJsonWhitespace(cursor + 1, objectEndExclusive)
            val valueStart = cursor
            val valueEnd = skipJsonValue(valueStart, objectEndExclusive) ?: return null
            if (keyMatches) {
                if (matchedValue != null) return null
                matchedValue = JsonValueRange(valueStart, valueEnd)
            }

            cursor = skipJsonWhitespace(valueEnd, objectEndExclusive)
            if (cursor >= objectEndExclusive) return null
            when (this[cursor]) {
                ',' -> cursor++
                '}' -> {
                    cursor = skipJsonWhitespace(cursor + 1, objectEndExclusive)
                    return matchedValue.takeIf { cursor == objectEndExclusive }
                }
                else -> return null
            }
        }
        return null
    }

    private fun String.skipJsonValue(start: Int, endExclusive: Int): Int? {
        if (start >= endExclusive) return null
        return when (this[start]) {
            '"' -> skipJsonString(start, endExclusive)
            '{', '[' -> skipJsonComposite(start, endExclusive)
            else -> {
                var cursor = start
                while (cursor < endExclusive &&
                    !this[cursor].isWhitespace() &&
                    this[cursor] != ',' &&
                    this[cursor] != '}' &&
                    this[cursor] != ']'
                ) {
                    cursor++
                }
                cursor.takeIf { it > start }
            }
        }
    }

    private fun String.skipJsonComposite(start: Int, endExclusive: Int): Int? {
        val closingTokens = ArrayDeque<Char>()
        closingTokens.addLast(if (this[start] == '{') '}' else ']')
        var cursor = start + 1
        while (cursor < endExclusive) {
            when (val token = this[cursor]) {
                '"' -> cursor = skipJsonString(cursor, endExclusive) ?: return null
                '{', '[' -> {
                    if (closingTokens.size >= MAX_JSON_NESTING_DEPTH) return null
                    closingTokens.addLast(if (token == '{') '}' else ']')
                    cursor++
                }
                '}', ']' -> {
                    if (closingTokens.removeLastOrNull() != token) return null
                    cursor++
                    if (closingTokens.isEmpty()) return cursor
                }
                else -> cursor++
            }
        }
        return null
    }

    private fun String.skipJsonString(start: Int, endExclusive: Int): Int? {
        if (start >= endExclusive || this[start] != '"') return null
        var cursor = start + 1
        while (cursor < endExclusive) {
            when (val token = this[cursor++]) {
                '"' -> return cursor
                '\\' -> {
                    if (cursor >= endExclusive) return null
                    when (this[cursor++]) {
                        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' -> Unit
                        'u' -> {
                            if (cursor + 4 > endExclusive) return null
                            if (substring(cursor, cursor + 4).toIntOrNull(16) == null) return null
                            cursor += 4
                        }
                        else -> return null
                    }
                }
                else -> {
                    if (token < ' ') return null
                }
            }
        }
        return null
    }

    private fun String.skipJsonWhitespace(start: Int, endExclusive: Int): Int {
        var cursor = start
        while (cursor < endExclusive && this[cursor].isWhitespace()) cursor++
        return cursor
    }

    private data class JsonValueRange(val start: Int, val endExclusive: Int)

    private const val MAX_JSON_NESTING_DEPTH = 64
}
