package com.ssrvpn.android

import android.net.VpnService

internal object VpnRouteInstaller {
    fun configure(builder: VpnService.Builder) {
        configure(builder::addAddress, builder::addRoute)
    }

    internal fun configure(
        addAddress: (String, Int) -> Unit,
        addRoute: (String, Int) -> Unit
    ) {
        addAddress("198.18.0.1", 32)
        addAddress(VpnIpv6Config.address, VpnIpv6Config.addressPrefixLength)
        for (route in PublicIpv4Routes.routes) {
            addRoute(route.address, route.prefixLength)
        }
        // IPv6 必须完整进入 VPN；只允许地址族但不添加 ::/0 会造成泄漏。
        addRoute(
            VpnIpv6Config.defaultRoute,
            VpnIpv6Config.defaultRoutePrefixLength
        )
    }
}
