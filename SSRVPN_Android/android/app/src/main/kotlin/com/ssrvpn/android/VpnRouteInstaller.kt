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
        // IPv6 必须完整进入 VPN，再由 Mihomo 的最高优先级规则拒绝；
        // 只允许地址族但不添加 ::/0 会绕过客户端的 IPv4-only 策略。
        addRoute(
            VpnIpv6Config.defaultRoute,
            VpnIpv6Config.defaultRoutePrefixLength
        )
    }
}
