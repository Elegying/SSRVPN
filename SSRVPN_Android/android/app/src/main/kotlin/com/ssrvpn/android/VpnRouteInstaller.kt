package com.ssrvpn.android

import android.net.VpnService

internal object VpnRouteInstaller {
    private const val clientAddress = "172.19.0.1"
    private const val clientPrefixLength = 30
    private const val dnsAddress = "172.19.0.2"

    fun configure(builder: VpnService.Builder) {
        configure(builder::addAddress, builder::addRoute, builder::addDnsServer)
    }

    internal fun configure(
        addAddress: (String, Int) -> Unit,
        addRoute: (String, Int) -> Unit,
        addDnsServer: (String) -> Unit
    ) {
        // Keep the interface and its synthetic DNS peer on a dedicated subnet.
        // The explicit /32 DNS route is required because 172.16.0.0/12 is
        // otherwise intentionally left outside the VPN for LAN compatibility.
        addAddress(clientAddress, clientPrefixLength)
        addAddress(VpnIpv6Config.address, VpnIpv6Config.addressPrefixLength)
        addDnsServer(dnsAddress)
        addRoute(dnsAddress, 32)
        for (route in PublicIpv4Routes.routes) {
            addRoute(route.address, route.prefixLength)
        }
        // IPv6 必须完整进入 VPN，再由 Mihomo 按目标执行直连或代理；
        // 只允许地址族但不添加 ::/0 会绕过客户端分流规则。
        addRoute(
            VpnIpv6Config.defaultRoute,
            VpnIpv6Config.defaultRoutePrefixLength
        )
    }
}
