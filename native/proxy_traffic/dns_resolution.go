package dns

import (
	"context"
	"net/netip"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	D "github.com/miekg/dns"
)

// Use the existing resolver, cache and policy for both questions. A stalled A
// question must not hide an already usable AAAA answer (or vice versa). This is
// DNS resolution, not an extra connectivity/capability probe.
func (r *Resolver) ssrvpnLookupIP(ctx context.Context, host string) ([]netip.Addr, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	type answer struct {
		kind uint16
		ips  []netip.Addr
	}
	answers := make(chan answer, 2)
	for _, kind := range []uint16{D.TypeA, D.TypeAAAA} {
		go func(kind uint16) {
			ips, err := r.lookupIP(ctx, host, kind)
			if err != nil {
				ips = nil
			}
			answers <- answer{kind, ips}
		}(kind)
	}
	wait := 100 * time.Millisecond
	if r != nil && r.ipv6Timeout > 0 {
		wait = r.ipv6Timeout
	}
	var timer *time.Timer
	var ready <-chan time.Time
	defer func() {
		if timer != nil {
			timer.Stop()
		}
	}()
	var ipv4, ipv6 []netip.Addr
	result := func() ([]netip.Addr, error) {
		ips := append(ipv4, ipv6...)
		if len(ips) == 0 {
			return nil, resolver.ErrIPNotFound
		}
		return ips, nil
	}
	for remaining := 2; remaining > 0; remaining-- {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-ready:
			return result()
		case a := <-answers:
			if a.kind == D.TypeA {
				ipv4 = a.ips
			} else {
				ipv6 = a.ips
			}
			if len(a.ips) > 0 && timer == nil {
				timer = time.NewTimer(wait)
				ready = timer.C
			}
		}
	}
	return result()
}
