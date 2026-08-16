package com.ssrvpn.android

import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnProtectMonitorTest {
    @Test
    fun `partial pipe reads are accumulated into one little endian descriptor`() {
        val input = object : InputStream() {
            private val bytes = byteArrayOf(0x78, 0x56, 0x34, 0x12)
            private var index = 0

            override fun read(): Int =
                if (index >= bytes.size) -1 else bytes[index++].toInt() and 0xFF

            override fun read(target: ByteArray, offset: Int, length: Int): Int {
                if (index >= bytes.size) return -1
                target[offset] = bytes[index++]
                return 1
            }
        }

        assertEquals(0x12345678, VpnProtectMonitor.readSocketFd(input))
        assertNull(VpnProtectMonitor.readSocketFd(input))
    }

    @Test
    fun `native linkage failure while reporting protect result is contained`() {
        val reported = VpnProtectMonitor.reportResultSafely(true) {
            throw LinkageError("missing native symbol")
        }

        assertFalse(reported)
    }

    @Test
    fun `stop closes the pipe reader and joins a blocked monitor`() {
        val readStarted = CountDownLatch(1)
        val inputClosed = AtomicBoolean(false)
        val input = object : InputStream() {
            @Volatile private var closed = false

            override fun read(): Int = -1

            override fun read(target: ByteArray, offset: Int, length: Int): Int {
                readStarted.countDown()
                while (!closed) Thread.sleep(1)
                return -1
            }

            override fun close() {
                inputClosed.set(true)
                closed = true
            }
        }
        val monitor = VpnProtectMonitor.start(
            input,
            protectSocket = { true },
            reportResult = {}
        )
        assertTrue(readStarted.await(1, TimeUnit.SECONDS))

        monitor.stop()
        monitor.thread.join(1_000)

        assertTrue(inputClosed.get())
        assertFalse(monitor.thread.isAlive)
    }
}
