package com.ssrvpn.android

import java.net.InetAddress
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhysicalTcpLatencyProbeTest {
    @Test fun rejectsSyntheticAndLocalStackAddresses() {
        for (address in listOf("198.18.0.1", "198.19.255.254", "127.0.0.1", "0.0.0.0", "169.254.1.2", "224.0.0.1", "::1")) {
            assertFalse(address, PhysicalTcpLatencyProbe.usableAddress(InetAddress.getByName(address)))
        }
        for (address in listOf("1.1.1.1", "192.168.1.1", "198.20.0.1")) {
            assertTrue(address, PhysicalTcpLatencyProbe.usableAddress(InetAddress.getByName(address)))
        }
    }
    @Test fun rejectsInvalidRequestsBeforeAllocatingNetworkWork() {
        assertTrue(PhysicalTcpLatencyProbe.validArguments("relay.example", 443, 5000))
        assertFalse(PhysicalTcpLatencyProbe.validArguments("bad\u0000host", 443, 5000))
        assertFalse(PhysicalTcpLatencyProbe.validArguments("relay.example", 65536, 5000))
        assertFalse(PhysicalTcpLatencyProbe.validArguments("relay.example", 443, 0))
    }
}
