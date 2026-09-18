package outbound

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"strings"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/iface"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
)

// Recover a failed DIRECT TCP dial before any application bytes were sent.
// Use the same DIRECT resolver and interface binding; never call from a proxy
// adapter. A literal target without a known hostname cannot change families.
func ssrvpnDirectFamilyFallback(ctx context.Context, metadata *C.Metadata, err error, lookup func(context.Context, string) ([]netip.Addr, error)) *C.Metadata {
	var dialError *net.OpError
	if err == nil || !(errors.As(err, &dialError) && dialError.Op == "dial" || strings.Contains(err.Error(), "bind6:")) || !metadata.DstIP.IsValid() || metadata.DNSMode == C.DNSHosts || metadata.Type == C.INNER || ctx.Err() != nil {
		return nil
	}
	host := metadata.Host
	if host == "" {
		host = metadata.SniffHost
	}
	if host == "" {
		return nil
	}
	lookupCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	ips, lookupErr := lookup(lookupCtx, host)
	if lookupErr != nil || lookupCtx.Err() != nil {
		return nil
	}
	for _, ip := range ips {
		ip = ip.Unmap()
		if !ip.IsValid() || ip.Is6() == metadata.DstIP.Unmap().Is6() || resolver.IsFakeIP(ip) {
			continue
		}
		target := metadata.Clone()
		target.Host = ""
		target.DstIP = ip
		return target
	}
	// Single-family targets still fail honestly. Never invent a mapping.
	return nil
}

// Absence of a usable local IPv6 source is definitive; its presence is NOT
// proof of IPv6 Internet reachability. Unknown/dual-stack keeps native racing.
// Reuse Mihomo's interface cache (20s, flushed by its network monitor), without
// an external probe or an OS subprocess on the connection path.
func ssrvpnPhysicalIPv4Only(i *iface.Interface) bool {
	if i == nil || i.Flags&net.FlagUp == 0 || i.Flags&net.FlagLoopback != 0 {
		return false
	}
	ipv4 := false
	for _, prefix := range i.Addresses {
		address := prefix.Addr().Unmap()
		if !address.IsGlobalUnicast() {
			continue
		}
		if address.Is6() {
			return false
		} // Includes ULA: do not assume it is unusable.
		ipv4 = true
	}
	return ipv4
}

func (d *Direct) ssrvpnDirectResolver() resolver.Resolver {
	r := resolver.DirectHostResolver
	if d.prefer != C.DualStack || dialer.DefaultSocketHook != nil {
		return r
	}
	name := d.iface
	if name == "" {
		name = dialer.DefaultInterface.Load()
	}
	if name == "" {
		if finder := dialer.DefaultInterfaceFinder.Load(); finder != nil {
			name = finder.FindInterfaceName(netip.IPv6Unspecified())
		}
	}
	if name == "" {
		return r
	}
	physical, err := iface.ResolveInterface(name)
	if err != nil || !ssrvpnPhysicalIPv4Only(physical) {
		return r
	}
	if r == nil || !r.Invalid() {
		r = resolver.SystemResolver
	}
	if r == nil {
		return nil
	}
	return ssrvpnIPv4SourceResolver{r}
}

type ssrvpnIPv4SourceResolver struct{ resolver.Resolver }

// Only DIRECT's domain resolution uses this view. DNS replies to applications,
// PROXY targets and proxy-server DNS remain dual-stack. Do not mistake an early
// AAAA-only partial result for an IPv6-only host before the A lookup completes.
func (r ssrvpnIPv4SourceResolver) LookupIP(ctx context.Context, host string) ([]netip.Addr, error) {
	ips, err := r.Resolver.LookupIPv4(ctx, host)
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if err == nil && len(ips) > 0 {
		return ips, nil
	}
	// Keep IPv6-only/local destinations honest; never invent an A record or
	// modify the chosen outbound. The native socket reports its own failure.
	return r.Resolver.LookupIP(ctx, host)
}
