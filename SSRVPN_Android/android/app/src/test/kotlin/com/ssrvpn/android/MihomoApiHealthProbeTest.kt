package com.ssrvpn.android

import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MihomoApiHealthProbeTest {
    @Test
    fun `a non-Mihomo service on the API port is a port conflict`() {
        ScriptedHttpServer(
            responses = listOf(httpResponse("not mihomo"))
        ).use { server ->
            assertEquals(
                MihomoApiReadiness.PORT_CONFLICT,
                MihomoApiHealthProbe.readiness(server.port, "secret", deadlineAfter(1_000))
            )
        }
    }

    @Test
    fun `controller credential rejections are not port conflicts`() {
        listOf(
            "HTTP/1.1 401 Unauthorized",
            "HTTP/1.1 403 Forbidden"
        ).forEach { status ->
            ScriptedHttpServer(
                responses = listOf(httpStatusResponse(status))
            ).use { server ->
                assertEquals(
                    MihomoApiReadiness.AUTH_REJECTED,
                    MihomoApiHealthProbe.readiness(
                        server.port,
                        "wrong-secret",
                        deadlineAfter(1_000)
                    )
                )
            }
        }
    }

    @Test
    fun `authenticated version and enabled TUN config are ready`() {
        ScriptedHttpServer(
            responses = listOf(
                httpResponse("{\"meta\":true,\"version\":\"v1.19.27\"}"),
                httpResponse("{\"tun\":{\"enable\":true,\"device\":\"SSRVPN\"}}")
            )
        ).use { server ->
            assertEquals(
                MihomoApiReadiness.READY,
                MihomoApiHealthProbe.readiness(server.port, "api-secret", deadlineAfter(1_000))
            )

            val requests = server.requests()
            assertTrue(requests[0].startsWith("GET /version HTTP/1.1"))
            assertTrue(requests[1].startsWith("GET /configs HTTP/1.1"))
            assertTrue(requests.all { it.contains("Authorization: Bearer api-secret") })
        }
    }

    @Test
    fun `enabled TUN remains ready when enable is not the first field`() {
        ScriptedHttpServer(
            responses = listOf(
                httpResponse("{\"meta\":true,\"version\":\"v1.19.27\"}"),
                httpResponse("{\"tun\":{\"device\":\"\",\"stack\":\"gvisor\",\"enable\":true}}")
            )
        ).use { server ->
            assertEquals(
                MihomoApiReadiness.READY,
                MihomoApiHealthProbe.readiness(server.port, "secret", deadlineAfter(1_000))
            )
        }
    }

    @Test
    fun `UTF-8 JSON content length is compared in bytes`() {
        ScriptedHttpServer(
            responses = listOf(
                httpResponse("{\"meta\":true,\"version\":\"版本一\"}"),
                httpResponse("{\"tun\":{\"device\":\"节点设备\",\"enable\":true}}")
            )
        ).use { server ->
            assertEquals(
                MihomoApiReadiness.READY,
                MihomoApiHealthProbe.readiness(server.port, "secret", deadlineAfter(1_000))
            )
        }
    }

    @Test
    fun `nested TUN decoy cannot override the top-level TUN state`() {
        ScriptedHttpServer(
            responses = listOf(
                httpResponse("{\"meta\":true,\"version\":\"v1.19.27\"}"),
                httpResponse(
                    "{\"shadow\":{\"tun\":{\"enable\":true}}," +
                        "\"tun\":{\"device\":\"\",\"enable\":false}}"
                )
            )
        ).use { server ->
            assertEquals(
                MihomoApiReadiness.TUN_DISABLED,
                MihomoApiHealthProbe.readiness(server.port, "secret", deadlineAfter(1_000))
            )
        }
    }

    @Test
    fun `string TUN enable value is not accepted as readiness`() {
        ScriptedHttpServer(
            responses = listOf(
                httpResponse("{\"meta\":true,\"version\":\"v1.19.27\"}"),
                httpResponse("{\"tun\":{\"enable\":\"true\"}}")
            )
        ).use { server ->
            assertEquals(
                MihomoApiReadiness.PENDING,
                MihomoApiHealthProbe.readiness(server.port, "secret", deadlineAfter(1_000))
            )
        }
    }

    @Test
    fun `enabled TUN does not require a device field`() {
        ScriptedHttpServer(
            responses = listOf(
                httpResponse("{\"meta\":true,\"version\":\"v1.19.27\"}"),
                httpResponse("{\"tun\":{\"enable\":true}}")
            )
        ).use { server ->
            assertEquals(
                MihomoApiReadiness.READY,
                MihomoApiHealthProbe.readiness(server.port, "secret", deadlineAfter(1_000))
            )
        }
    }

    @Test
    fun `missing TUN or enable field remains pending`() {
        listOf(
            "{\"mode\":\"rule\"}",
            "{\"tun\":{\"device\":\"\"}}"
        ).forEach { config ->
            ScriptedHttpServer(
                responses = listOf(
                    httpResponse("{\"meta\":true,\"version\":\"v1.19.27\"}"),
                    httpResponse(config)
                )
            ).use { server ->
                assertEquals(
                    MihomoApiReadiness.PENDING,
                    MihomoApiHealthProbe.readiness(
                        server.port,
                        "secret",
                        deadlineAfter(1_000)
                    )
                )
            }
        }
    }

    @Test
    fun `valid TUN prefix cannot hide a malformed trailing config`() {
        ScriptedHttpServer(
            responses = listOf(
                httpResponse("{\"meta\":true,\"version\":\"v1.19.27\"}"),
                httpResponse("{\"tun\":{\"enable\":true},\"broken\"}")
            )
        ).use { server ->
            assertEquals(
                MihomoApiReadiness.PENDING,
                MihomoApiHealthProbe.readiness(server.port, "secret", deadlineAfter(1_000))
            )
        }
    }

    @Test
    fun `Mihomo with disabled TUN is reported explicitly`() {
        ScriptedHttpServer(
            responses = listOf(
                httpResponse("{\"meta\":true,\"version\":\"v1.19.27\"}"),
                httpResponse("{\"tun\":{\"enable\":false}}")
            )
        ).use { server ->
            assertEquals(
                MihomoApiReadiness.TUN_DISABLED,
                MihomoApiHealthProbe.readiness(server.port, "secret", deadlineAfter(1_000))
            )
        }
    }

    @Test
    fun `runtime health remains a lightweight version probe`() {
        ScriptedHttpServer(
            responses = listOf(httpResponse("{\"meta\":true,\"version\":\"v1.19.27\"}"))
        ).use { server ->
            assertTrue(
                MihomoApiHealthProbe.isHealthy(
                    server.port,
                    "secret",
                    deadlineAfter(1_000)
                )
            )
        }
    }

    @Test
    fun `runtime readiness keeps the concrete authentication failure category`() {
        ScriptedHttpServer(
            responses = listOf(httpStatusResponse("HTTP/1.1 401 Unauthorized"))
        ).use { server ->
            assertEquals(
                MihomoApiReadiness.AUTH_REJECTED,
                MihomoApiHealthProbe.runtimeReadiness(
                    server.port,
                    "wrong-secret",
                    deadlineAfter(1_000)
                )
            )
        }
    }

    @Test
    fun `an unavailable API remains pending for the waiter to retry`() {
        val port = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }

        assertEquals(
            MihomoApiReadiness.PENDING,
            MihomoApiHealthProbe.readiness(port, "secret", deadlineAfter(1_000))
        )
    }

    @Test
    fun `a truncated API response remains pending instead of claiming a port conflict`() {
        ScriptedHttpServer(
            responses = listOf(truncatedJsonResponse("{\"meta\":true"))
        ).use { server ->
            assertEquals(
                MihomoApiReadiness.PENDING,
                MihomoApiHealthProbe.readiness(
                    server.port,
                    "secret",
                    deadlineAfter(1_000)
                )
            )
        }
    }

    @Test
    fun `a slow response cannot outlive the probe budget`() {
        ScriptedHttpServer(
            responses = listOf(httpResponse("{\"meta\":true,\"version\":\"v1.19.27\"}")),
            headerByteDelayMillis = 25
        ).use { server ->
            val startedAt = System.nanoTime()
            val readiness =
                MihomoApiHealthProbe.readiness(server.port, "secret", deadlineAfter(150))
            val elapsedMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt)

            assertEquals(MihomoApiReadiness.TIMEOUT, readiness)
            assertTrue("probe exceeded its total budget: ${elapsedMillis}ms", elapsedMillis < 1_000)
        }
    }

    @Test
    fun `a slow response body cannot outlive the probe budget`() {
        ScriptedHttpServer(
            responses = listOf(httpResponse("{\"meta\":true,\"version\":\"v1.19.27\"}")),
            bodyByteDelayMillis = 75
        ).use { server ->
            val startedAt = System.nanoTime()
            val readiness =
                MihomoApiHealthProbe.readiness(server.port, "secret", deadlineAfter(150))
            val elapsedMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt)

            assertEquals(MihomoApiReadiness.TIMEOUT, readiness)
            assertTrue("probe exceeded its total budget: ${elapsedMillis}ms", elapsedMillis < 1_000)
        }
    }

    private class ScriptedHttpServer(
        private val responses: List<String?>,
        private val headerByteDelayMillis: Long = 0,
        private val bodyByteDelayMillis: Long = 0
    ) : AutoCloseable {
        private val socket = ServerSocket(
            0,
            responses.size.coerceAtLeast(1),
            InetAddress.getLoopbackAddress()
        )
        private val executor = Executors.newSingleThreadExecutor()
        private val requestsFuture: Future<List<String>> = executor.submit<List<String>> {
            responses.map { response ->
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
                            writeBytes(
                                output,
                                response.substring(0, headerEnd).toByteArray(Charsets.UTF_8),
                                headerByteDelayMillis
                            )
                            writeBytes(
                                output,
                                response.substring(headerEnd).toByteArray(Charsets.UTF_8),
                                bodyByteDelayMillis
                            )
                        }
                    }
                    request
                }
            }
        }

        val port: Int
            get() = socket.localPort

        fun requests(): List<String> = requestsFuture.get(2, TimeUnit.SECONDS)

        private fun writeBytes(
            output: java.io.OutputStream,
            bytes: ByteArray,
            delayMillis: Long
        ) {
            if (delayMillis == 0L) {
                output.write(bytes)
                output.flush()
                return
            }
            bytes.forEach { byte ->
                output.write(byte.toInt())
                output.flush()
                Thread.sleep(delayMillis)
            }
        }

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

        private fun httpStatusResponse(statusLine: String): String = buildString {
            append("$statusLine\r\n")
            append("Content-Length: 0\r\n")
            append("Connection: close\r\n")
            append("\r\n")
        }

        private fun truncatedJsonResponse(body: String): String = buildString {
            append("HTTP/1.1 200 OK\r\n")
            append("Content-Type: application/json\r\n")
            append("Content-Length: ${body.toByteArray(Charsets.UTF_8).size + 16}\r\n")
            append("Connection: close\r\n")
            append("\r\n")
            append(body)
        }
    }
}
