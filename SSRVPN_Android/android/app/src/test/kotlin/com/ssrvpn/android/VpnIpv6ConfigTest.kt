package com.ssrvpn.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnIpv6ConfigTest {
    @Test
    fun `VPN captures all IPv6 traffic without leaking`() {
        assertEquals("fdfe:dcba:9876::1", VpnIpv6Config.address)
        assertEquals(126, VpnIpv6Config.addressPrefixLength)
        assertEquals("::", VpnIpv6Config.defaultRoute)
        assertEquals(0, VpnIpv6Config.defaultRoutePrefixLength)
    }

    @Test
    fun `route installer applies both addresses public IPv4 and IPv6 default`() {
        val addresses = mutableListOf<Pair<String, Int>>()
        val routes = mutableListOf<Pair<String, Int>>()
        val dnsServers = mutableListOf<String>()

        VpnRouteInstaller.configure(
            addAddress = { address, prefix -> addresses += address to prefix },
            addRoute = { address, prefix -> routes += address to prefix },
            addDnsServer = dnsServers::add
        )

        assertEquals(
            listOf("172.19.0.1" to 30, "fdfe:dcba:9876::1" to 126),
            addresses
        )
        assertEquals(listOf("172.19.0.2"), dnsServers)
        assertTrue(routes.contains("172.19.0.2" to 32))
        assertTrue(routes.contains("102.0.0.0" to 7))
        assertTrue(routes.contains("::" to 0))
    }
}
