package com.ssrvpn.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PublicIpv4RoutesTest {
    @Test
    fun `all representative public ranges enter the VPN`() {
        for (address in listOf(
            "1.1.1.1",
            "8.8.8.8",
            "11.0.0.1",
            "102.1.2.3",
            "103.1.2.3",
            "170.1.2.3",
            "223.255.255.254",
        )) {
            assertTrue("missing public route for $address", isRouted(address))
        }
    }

    @Test
    fun `documented local ranges stay outside the VPN`() {
        for (address in listOf(
            "10.1.2.3",
            "100.64.0.1",
            "172.16.0.1",
            "192.168.1.1",
        )) {
            assertFalse("local route unexpectedly captured: $address", isRouted(address))
        }
    }

    private fun isRouted(address: String): Boolean {
        val value = address.toIpv4Long()
        return PublicIpv4Routes.routes.any { route ->
            val mask = if (route.prefixLength == 0) {
                0L
            } else {
                (0xffffffffL shl (32 - route.prefixLength)) and 0xffffffffL
            }
            value and mask == route.address.toIpv4Long() and mask
        }
    }

    private fun String.toIpv4Long(): Long =
        split('.').fold(0L) { value, octet -> (value shl 8) or octet.toLong() }
}
