package outbound

import (
	"context"
	"fmt"
	"net/netip"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
)

// This is an explicit per-node declaration, never inferred from one failed
// connection. It restricts remote destinations, not the address of the server.
// Called by the selected HY2 adapter, so DIRECT and other nodes are untouched.
func ssrvpnEgressTarget(ctx context.Context, original *C.Metadata, policy string, udp bool,
	lookup4 func(context.Context, string) (netip.Addr, error)) (*C.Metadata, error) {
	if policy != "ipv4" {
		return original, nil
	}
	target := original.Clone()
	host := target.Host
	if host == "" && target.DNSMode != C.DNSHosts {
		host = target.SniffHost
	}
	if ip, err := netip.ParseAddr(host); err == nil {
		target.DstIP = ip.Unmap()
		target.Host = ""
		host = ""
	}
	ip := target.DstIP.Unmap()
	if ip.Is4() && !resolver.IsFakeIP(ip) {
		target.DstIP = ip
		if target.DNSMode == C.DNSHosts {
			target.Host = ""
		}
		return target, nil
	}
	// Explicit hosts entries must keep their chosen address. Only a known
	// hostname may recover a mapped/fake/sniffed target; this is not NAT64.
	if host == "" || target.DNSMode == C.DNSHosts {
		log.Infoln("[SSRVPN_IPV6_TARGET_UNSUPPORTED] selected node declares IPv4-only egress")
		return nil, fmt.Errorf("IPv4-only node cannot reach literal IPv6 target: %w", resolver.ErrIPNotFound)
	}
	target.Host = host
	target.DstIP = netip.Addr{}
	if udp {
		lookupCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		ip, err := lookup4(lookupCtx, host)
		if err != nil {
			return nil, err
		}
		if !ip.Unmap().Is4() || resolver.IsFakeIP(ip) {
			return nil, resolver.ErrIPNotFound
		}
		target.DstIP = ip.Unmap()
	}
	return target, nil
}
