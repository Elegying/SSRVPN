package outbound

import (
	"context"
	"errors"
	"net/netip"
	"testing"

	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
)

func TestSSRVPNEgressPolicy(t *testing.T) {
	v6 := netip.MustParseAddr("2001:db8::1")
	v4 := netip.MustParseAddr("192.0.2.1")
	lookups := 0
	lookup := func(context.Context, string) (netip.Addr, error) { lookups++; return v4, nil }
	for _, udp := range []bool{false, true} {
		literal := &C.Metadata{DstIP: v6}
		if result, err := ssrvpnEgressTarget(context.Background(), literal, "auto", udp, lookup); err != nil || result != literal {
			t.Fatal("unknown node capability changed behavior")
		}
		if _, err := ssrvpnEgressTarget(context.Background(), literal, "ipv4", udp, lookup); !errors.Is(err, resolver.ErrIPNotFound) {
			t.Fatal("literal IPv6 must fail before a proxy connection is opened", err)
		}
		if lookups != 0 {
			t.Fatal("literal target triggered DNS")
		}
	}
	for _, udp := range []bool{false, true} {
		for _, sniff := range []bool{false, true} {
			mapped := &C.Metadata{DstIP: v6, DNSMode: C.DNSMapping, Host: "dual.example.test"}
			if sniff {
				mapped.SniffHost, mapped.Host = mapped.Host, ""
			}
			result, err := ssrvpnEgressTarget(context.Background(), mapped, "ipv4", udp, lookup)
			if err != nil || result.Host != "dual.example.test" || mapped.DstIP != v6 {
				t.Fatal("hostname recovery changed original metadata", err)
			}
			if udp && result.DstIP != v4 || !udp && result.DstIP.IsValid() {
				t.Fatal("TCP must retain remote DNS; UDP must select IPv4")
			}
		}
	}
	hosts := &C.Metadata{Host: "fixed.example.test", DstIP: v6, DNSMode: C.DNSHosts}
	if _, err := ssrvpnEgressTarget(context.Background(), hosts, "ipv4", false, lookup); !errors.Is(err, resolver.ErrIPNotFound) {
		t.Fatal("explicit hosts mapping was overridden")
	}
	for _, address := range []string{"192.0.2.1", "::ffff:192.0.2.1"} {
		result, err := ssrvpnEgressTarget(context.Background(), &C.Metadata{DstIP: netip.MustParseAddr(address)}, "ipv4", false, lookup)
		if err != nil || result.DstIP != v4 {
			t.Fatal("IPv4 was blocked", err)
		}
		result, err = ssrvpnEgressTarget(context.Background(), &C.Metadata{Host: address}, "ipv4", false, lookup)
		if err != nil || result.String() != "192.0.2.1" {
			t.Fatal("literal hostname was not normalized", err)
		}
	}
	result, err := ssrvpnEgressTarget(context.Background(), &C.Metadata{Host: "fixed.example.test", DstIP: v4, DNSMode: C.DNSHosts}, "ipv4", false, lookup)
	if err != nil || result.String() != "192.0.2.1" {
		t.Fatal("explicit IPv4 hosts mapping was overridden", err)
	}
	// A nil client makes accidental transport access fail this regression.
	adapter := &Hysteria2{Base: NewBase(BaseOption{}), option: &Hysteria2Option{SSRVPNEgress: "ipv4"}}
	literal := &C.Metadata{DstIP: v6}
	if _, err := adapter.DialContext(context.Background(), literal); !errors.Is(err, resolver.ErrIPNotFound) {
		t.Fatal("TCP did not reject before transport access", err)
	}
	if _, err := adapter.ListenPacketContext(context.Background(), literal); !errors.Is(err, resolver.ErrIPNotFound) {
		t.Fatal("UDP did not reject before transport access", err)
	}
	if _, err := NewHysteria2(Hysteria2Option{SSRVPNEgress: "typo"}); err == nil {
		t.Fatal("unsupported declaration silently accepted")
	}
}
