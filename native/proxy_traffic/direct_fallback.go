package outbound

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"strings"
	"time"

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
