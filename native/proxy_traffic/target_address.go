package tunnel

import (
	"context"
	"net/netip"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
)

// Apply only after routing. Proxy-server addresses and internal DNS transports
// keep their own resolver: resolving those here would recurse through DNS.
func ssrvpnProxyTargetCandidates(ctx context.Context, metadata *C.Metadata, proxy C.Proxy) []*C.Metadata {
	if resolver.DisableIPv6 || metadata.Type == C.INNER || metadata.DNSMode == C.DNSHosts {
		return []*C.Metadata{metadata}
	}
	for depth := 0; depth < 16; depth++ {
		next := proxy.Unwrap(metadata, false)
		if next == nil {
			switch proxy.Type() {
			case C.Direct, C.Reject, C.RejectDrop, C.Compatible, C.Pass, C.PassRule, C.Dns:
				return []*C.Metadata{metadata}
			}
			return ssrvpnTargetCandidates(ctx, metadata, resolver.LookupIP)
		}
		proxy = next
	}
	return []*C.Metadata{metadata}
}

// This is address selection, not NAT64. A literal IPv6 address with no known
// hostname cannot be converted. Keep TLS/HTTP bytes and original log metadata
// intact; only the proxy protocol's destination address changes.
func ssrvpnTargetCandidates(ctx context.Context, metadata *C.Metadata, lookup func(context.Context, string) ([]netip.Addr, error)) []*C.Metadata {
	host := metadata.Host
	if host == "" && metadata.DstIP.Is6() {
		host = metadata.SniffHost
	}
	if host == "" {
		return []*C.Metadata{metadata}
	}
	if metadata.DstIP.Is4() {
		next := metadata.Clone()
		next.Host = ""
		return []*C.Metadata{next, metadata}
	}
	lookupCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	ips, err := lookup(lookupCtx, host)
	if err != nil || len(ips) == 0 {
		// Remote DNS through the already selected proxy remains available. Never
		// fall back to DIRECT or turn a transient DNS failure into a disconnection.
		return []*C.Metadata{metadata}
	}
	candidates := make([]*C.Metadata, 0, 9)
	seen := make(map[netip.Addr]bool)
	for _, ipv4 := range []bool{true, false} {
		count := 0
		for _, ip := range ips {
			ip = ip.Unmap()
			if !ip.IsValid() || ip.Is4() != ipv4 || seen[ip] || resolver.IsFakeIP(ip) {
				continue
			}
			seen[ip] = true
			next := metadata.Clone()
			next.Host = ""
			next.DstIP = ip
			candidates = append(candidates, next)
			count++
			if count == 4 {
				break
			}
		}
	}
	// The existing bounded core retry loop tries alternate addresses, then the
	// original hostname (server-side DNS). It never selects another proxy node.
	return append(candidates, metadata)
}

func ssrvpnTargetAt(candidates []*C.Metadata, attempt int) *C.Metadata {
	if attempt >= len(candidates) {
		attempt = len(candidates) - 1
	}
	return candidates[attempt]
}

func ssrvpnLogIPv6TargetFailure(candidates []*C.Metadata, attempts int, record func()) {
	for index, metadata := range candidates {
		if index >= attempts {
			break
		}
		if !metadata.DstIP.Is6() {
			continue
		}
		// A failed attempt is not proof of node-wide IPv6 capability. No host, URL,
		// credentials or raw errors are needed for this user-facing observation.
		record()
		log.Warnln("[SSRVPN_IPV6_TARGET_FAILED] IPv6 target connection failed through the selected route")
		return
	}
}
