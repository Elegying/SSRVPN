package com.ssrvpn.android

internal data class Ipv4Route(val address: String, val prefixLength: Int)

/**
 * IPv4 routes sent through the VPN while the four documented local ranges stay
 * on the physical network for LAN devices, casting and wireless debugging.
 */
internal object PublicIpv4Routes {
    val routes = listOf(
        Ipv4Route("1.0.0.0", 8),
        Ipv4Route("2.0.0.0", 7),
        Ipv4Route("4.0.0.0", 6),
        Ipv4Route("8.0.0.0", 7),
        Ipv4Route("11.0.0.0", 8),
        Ipv4Route("12.0.0.0", 6),
        Ipv4Route("16.0.0.0", 4),
        Ipv4Route("32.0.0.0", 3),
        Ipv4Route("64.0.0.0", 3),
        Ipv4Route("96.0.0.0", 6),
        Ipv4Route("100.0.0.0", 10),
        Ipv4Route("100.128.0.0", 9),
        Ipv4Route("101.0.0.0", 8),
        Ipv4Route("102.0.0.0", 7),
        Ipv4Route("104.0.0.0", 5),
        Ipv4Route("112.0.0.0", 4),
        Ipv4Route("128.0.0.0", 3),
        Ipv4Route("160.0.0.0", 5),
        Ipv4Route("168.0.0.0", 6),
        Ipv4Route("172.0.0.0", 12),
        Ipv4Route("172.32.0.0", 11),
        Ipv4Route("172.64.0.0", 10),
        Ipv4Route("172.128.0.0", 9),
        Ipv4Route("173.0.0.0", 8),
        Ipv4Route("174.0.0.0", 7),
        Ipv4Route("176.0.0.0", 4),
        Ipv4Route("192.0.0.0", 16),
        Ipv4Route("192.1.0.0", 16),
        Ipv4Route("192.2.0.0", 15),
        Ipv4Route("192.4.0.0", 14),
        Ipv4Route("192.8.0.0", 13),
        Ipv4Route("192.16.0.0", 12),
        Ipv4Route("192.32.0.0", 11),
        Ipv4Route("192.64.0.0", 10),
        Ipv4Route("192.128.0.0", 11),
        Ipv4Route("192.160.0.0", 13),
        Ipv4Route("192.169.0.0", 16),
        Ipv4Route("192.170.0.0", 15),
        Ipv4Route("192.172.0.0", 14),
        Ipv4Route("192.176.0.0", 12),
        Ipv4Route("192.192.0.0", 10),
        Ipv4Route("193.0.0.0", 8),
        Ipv4Route("194.0.0.0", 7),
        Ipv4Route("196.0.0.0", 6),
        Ipv4Route("200.0.0.0", 5),
        Ipv4Route("208.0.0.0", 4),
    )
}
