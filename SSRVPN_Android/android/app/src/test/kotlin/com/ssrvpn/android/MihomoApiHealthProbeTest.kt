package com.ssrvpn.android

import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MihomoApiHealthProbeTest {
    @Test
    fun `an open TCP port without an HTTP response is not healthy`() {
        OneShotHttpServer(response = null).use { server ->
            assertFalse(MihomoApiHealthProbe.isHealthy(server.port, "secret", deadlineAfter(1_000)))
        }
    }

    @Test
    fun `an HTTP success with a garbage body is not healthy`() {
        OneShotHttpServer(
            response = httpResponse("not mihomo")
        ).use { server ->
            assertFalse(MihomoApiHealthProbe.isHealthy(server.port, "secret", deadlineAfter(1_000)))
        }
    }

    @Test
    fun `an authenticated Mihomo version response is healthy`() {
        OneShotHttpServer(
            response = httpResponse("{\"meta\":true,\"version\":\"v1.19.27\"}")
        ).use { server ->
            assertTrue(
                MihomoApiHealthProbe.isHealthy(
                    server.port,
                    "api-secret",
                    deadlineAfter(1_000)
                )
            )

            val request = server.request()
            assertTrue(request.startsWith("GET /version HTTP/1.1"))
            assertTrue(request.contains("Authorization: Bearer api-secret"))
        }
    }

    @Test
    fun `a slow response body cannot outlive the total probe budget`() {
        OneShotHttpServer(
            response = httpResponse("{\"meta\":true,\"version\":\"v1.19.27\"}"),
            bodyByteDelayMillis = 75
        ).use { server ->
            val startedAt = System.nanoTime()
            val healthy =
                MihomoApiHealthProbe.isHealthy(server.port, "secret", deadlineAfter(150))
            val elapsedMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt)

            assertFalse(healthy)
            assertTrue("probe exceeded its total budget: ${elapsedMillis}ms", elapsedMillis < 1_000)
        }
    }

    @Test
    fun `slow response headers cannot outlive the total probe budget`() {
        OneShotHttpServer(
            response = httpResponse("{\"meta\":true,\"version\":\"v1.19.27\"}"),
            headerByteDelayMillis = 25
        ).use { server ->
            val startedAt = System.nanoTime()
            val healthy =
                MihomoApiHealthProbe.isHealthy(server.port, "secret", deadlineAfter(150))
            val elapsedMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt)

            assertFalse(healthy)
            assertTrue("probe exceeded its total budget: ${elapsedMillis}ms", elapsedMillis < 1_000)
        }
    }

    private class OneShotHttpServer(
        response: String?,
        private val headerByteDelayMillis: Long = 0,
        private val bodyByteDelayMillis: Long = 0
    ) : AutoCloseable {
        private val socket = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        private val executor = Executors.newSingleThreadExecutor()
        private val requestFuture: Future<String> = executor.submit<String> {
            socket.accept().use { client ->
                client.soTimeout = 2_000
                val request = buildString {
                    val reader = client.getInputStream().bufferedReader()
                    while (true) {
                        val line = reader.readLine() ?: break
                        appendLine(line)
                        if (line.isEmpty()) break
                    }
                }
                if (response != null) {
                    client.getOutputStream().use { output ->
                        val headerEnd = response.indexOf("\r\n\r\n") + 4
                        val header = response.substring(0, headerEnd).toByteArray(Charsets.UTF_8)
                        if (headerByteDelayMillis == 0L) {
                            output.write(header)
                            output.flush()
                        } else {
                            header.forEach { byte ->
                                output.write(byte.toInt())
                                output.flush()
                                Thread.sleep(headerByteDelayMillis)
                            }
                        }
                        response.substring(headerEnd).toByteArray(Charsets.UTF_8).forEach { byte ->
                            output.write(byte.toInt())
                            output.flush()
                            if (bodyByteDelayMillis > 0) Thread.sleep(bodyByteDelayMillis)
                        }
                    }
                }
                request
            }
        }

        val port: Int
            get() = socket.localPort

        fun request(): String = requestFuture.get(2, TimeUnit.SECONDS)

        override fun close() {
            socket.close()
            executor.shutdownNow()
            executor.awaitTermination(2, TimeUnit.SECONDS)
        }
    }

    companion object {
        private fun deadlineAfter(timeoutMillis: Long): Long =
            System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis)

        private fun httpResponse(
            body: String,
            contentType: String = "application/json"
        ): String = buildString {
            append("HTTP/1.1 200 OK\r\n")
            append("Content-Type: $contentType\r\n")
            append("Content-Length: ${body.toByteArray(Charsets.UTF_8).size}\r\n")
            append("Connection: close\r\n")
            append("\r\n")
            append(body)
        }
    }
}
