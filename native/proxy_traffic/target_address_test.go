package tunnel

import (
	"context"
	"errors"
	"net/netip"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
)

func TestSSRVPNTargetAddressPreference(t *testing.T) {
	original := &C.Metadata{Host: "dual.example", DstPort: 443, NetWork: C.TCP}
	lookup := func(context.Context, string) ([]netip.Addr, error) {
		return []netip.Addr{netip.MustParseAddr("2001:db8::2"), netip.MustParseAddr("192.0.2.2"), netip.MustParseAddr("192.0.2.3"), netip.MustParseAddr("192.0.2.2")}, nil
	}
	candidates := ssrvpnTargetCandidates(context.Background(), original, lookup)
	if len(candidates) != 4 || candidates[0].DstIP.String() != "192.0.2.2" || !candidates[1].DstIP.Is4() || !candidates[2].DstIP.Is6() {
		t.Fatalf("wrong preference: %+v", candidates)
	}
	if candidates[0].Host != "" || candidates[0].RemoteAddress() != "192.0.2.2:443" {
		t.Fatal("outbound must use selected numeric target")
	}
	if original.Host != "dual.example" || original.DstIP.IsValid() {
		t.Fatal("modified original routing/log metadata")
	}
	if ssrvpnTargetAt(candidates, 20) != original {
		t.Fatal("must keep remote DNS fallback on the same proxy")
	}
}

func TestSSRVPNIPv6OnlyAndLiteralTargets(t *testing.T) {
	lookup := func(context.Context, string) ([]netip.Addr, error) {
		return []netip.Addr{netip.MustParseAddr("2001:db8::2")}, nil
	}
	original := &C.Metadata{Host: "v6.example", DstPort: 443}
	candidates := ssrvpnTargetCandidates(context.Background(), original, lookup)
	if len(candidates) != 2 || candidates[0].RemoteAddress() != "[2001:db8::2]:443" {
		t.Fatal("IPv6-only must reach proxy")
	}
	for _, ip := range []string{"2001:db8::1", "192.0.2.1"} {
		literal := &C.Metadata{DstIP: netip.MustParseAddr(ip)}
		result := ssrvpnTargetCandidates(context.Background(), literal, func(context.Context, string) ([]netip.Addr, error) {
			t.Fatal("literal address has no hostname to convert")
			return nil, nil
		})
		if result[0] != literal {
			t.Fatal("literal target changed")
		}
	}
}

func TestSSRVPNTargetLookupFailureAndCancellation(t *testing.T) {
	original := &C.Metadata{Host: "failed.example"}
	for _, empty := range []bool{false, true} {
		result := ssrvpnTargetCandidates(context.Background(), original, func(ctx context.Context, _ string) ([]netip.Addr, error) {
			deadline, ok := ctx.Deadline()
			if !ok || time.Until(deadline) > 2*time.Second {
				t.Fatal("missing lookup budget")
			}
			if empty {
				return nil, nil
			}
			return nil, errors.New("lookup failed")
		})
		if len(result) != 1 || result[0] != original {
			t.Fatal("lookup failure must retain proxy destination")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	ssrvpnTargetCandidates(ctx, original, func(ctx context.Context, _ string) ([]netip.Addr, error) {
		if ctx.Err() != context.Canceled {
			t.Fatal("lost cancellation")
		}
		return nil, ctx.Err()
	})
}

type ssrvpnFixtureProxy struct {
	C.Proxy
	kind C.AdapterType
	next C.Proxy
}

func (p ssrvpnFixtureProxy) Type() C.AdapterType              { return p.kind }
func (p ssrvpnFixtureProxy) Unwrap(*C.Metadata, bool) C.Proxy { return p.next }

func TestSSRVPNDirectAndInternalTrafficUnchanged(t *testing.T) {
	previous := resolver.DisableIPv6
	resolver.DisableIPv6 = false
	defer func() { resolver.DisableIPv6 = previous }()
	for _, kind := range []C.AdapterType{C.Direct, C.Reject} {
		proxy := ssrvpnFixtureProxy{kind: kind}
		original := &C.Metadata{Host: "should-not-resolve.invalid"}
		for _, selected := range []C.Proxy{proxy, ssrvpnFixtureProxy{next: proxy}} {
			result := ssrvpnProxyTargetCandidates(context.Background(), original, selected)
			if len(result) != 1 || result[0] != original {
				t.Fatal("non-proxy destination changed")
			}
		}
	}
	proxy := ssrvpnFixtureProxy{kind: C.Http}
	original := &C.Metadata{Host: "dns-transport.invalid", Type: C.INNER}
	if ssrvpnProxyTargetCandidates(context.Background(), original, proxy)[0] != original {
		t.Fatal("internal DNS must not recurse")
	}
}

func TestSSRVPNMappedIPv4AndSniffedIPv6(t *testing.T) {
	mapped := &C.Metadata{Host: "mapped.example", DstIP: netip.MustParseAddr("192.0.2.1")}
	result := ssrvpnTargetCandidates(context.Background(), mapped, func(context.Context, string) ([]netip.Addr, error) {
		t.Fatal("already resolved IPv4 needs no extra lookup")
		return nil, nil
	})
	if result[0].Host != "" || result[0].DstIP != mapped.DstIP || result[1] != mapped {
		t.Fatal("mapped IPv4 was not pinned with fallback")
	}
	sniffed := &C.Metadata{SniffHost: "known.example", DstIP: netip.MustParseAddr("2001:db8::1")}
	result = ssrvpnTargetCandidates(context.Background(), sniffed, func(_ context.Context, host string) ([]netip.Addr, error) {
		if host != "known.example" {
			t.Fatal(host)
		}
		return []netip.Addr{netip.MustParseAddr("192.0.2.1")}, nil
	})
	if !result[0].DstIP.Is4() || result[1] != sniffed || !sniffed.DstIP.Is6() {
		t.Fatal("sniffed IPv6 fallback lost")
	}
}

func TestSSRVPNIPv6ObservationRequiresAnActualAttempt(t *testing.T) {
	candidates := []*C.Metadata{{DstIP: netip.MustParseAddr("192.0.2.1")}, {DstIP: netip.MustParseAddr("2001:db8::1")}}
	count := 0
	ssrvpnLogIPv6TargetFailure(candidates, 1, func() { count++ })
	if count != 0 {
		t.Fatal("untested IPv6 candidate must not become a failure observation")
	}
	ssrvpnLogIPv6TargetFailure(candidates, 2, func() { count++ })
	if count != 1 {
		t.Fatal("attempted IPv6 failure was not recorded")
	}
}
