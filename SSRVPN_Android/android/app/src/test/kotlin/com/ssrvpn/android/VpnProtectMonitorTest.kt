package com.ssrvpn.android

import java.io.InputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
}
