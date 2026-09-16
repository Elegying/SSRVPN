// Isolated source-boundary test; copy into the fixed core's config package.
// No TUN, routes, DNS, firewall, or operating-system settings are changed.
package config

import (
	"net/netip"
	"testing"
)

func TestAuditIPv4OnlyRetainsRequiredTunIPv6Capture(t *testing.T) {
	raw := &RawConfig{IPv6: false}
	raw.Tun.Inet6Address = []netip.Prefix{netip.MustParsePrefix("fdfe:dcba:9876::1/126")}
	parseIPV6(raw)
	if len(raw.Tun.Inet6Address) == 0 {
		t.Fatal("production parser discarded the configured TUN IPv6 address; an emitted inet6-address alone cannot prove IPv6 capture")
	}
}
