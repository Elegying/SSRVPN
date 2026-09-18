package outbound

import (
	"context"
	"errors"
	C "github.com/metacubex/mihomo/constant"
	"net"
	"net/netip"
	"testing"
	"time"
)

func TestSSRVPNDirectBind6Fallback(t *testing.T) {
	original := &C.Metadata{DstIP: netip.MustParseAddr("2001:db8::1"), SniffHost: "dual.example", DstPort: 443}
	failure := errors.New("dial tcp [2001:db8::1]:443: bind6: An invalid argument was supplied.")
	calls := 0
	lookup := func(ctx context.Context, host string) ([]netip.Addr, error) {
		calls++
		deadline, ok := ctx.Deadline()
		if host != "dual.example" || !ok || time.Until(deadline) > 2*time.Second {
			t.Fatal("lost domain or bounded lookup")
		}
		return []netip.Addr{netip.MustParseAddr("2001:db8::1"), netip.MustParseAddr("192.0.2.2")}, nil
	}
	target := ssrvpnDirectFamilyFallback(context.Background(), original, failure, lookup)
	if target == nil || target.RemoteAddress() != "192.0.2.2:443" || !original.DstIP.Is6() || target.Host != "" {
		t.Fatal("fallback must pin IPv4 without mutating original")
	}
	for _, err := range []error{nil, errors.New("i/o timeout"), errors.New("certificate mismatch")} {
		if ssrvpnDirectFamilyFallback(context.Background(), original, err, lookup) != nil {
			t.Fatal("unrelated error retried")
		}
	}
	for _, modify := range []func(*C.Metadata){
		func(m *C.Metadata) { m.SniffHost = "" },
		func(m *C.Metadata) { m.DNSMode = C.DNSHosts },
		func(m *C.Metadata) { m.Type = C.INNER },
	} {
		m := original.Clone()
		modify(m)
		if ssrvpnDirectFamilyFallback(context.Background(), m, failure, lookup) != nil {
			t.Fatal("protected destination changed")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if ssrvpnDirectFamilyFallback(ctx, original, failure, lookup) != nil {
		t.Fatal("ignored cancellation")
	}
	if calls != 1 {
		t.Fatalf("unexpected DNS requests: %d", calls)
	}
	for _, answer := range [][]netip.Addr{nil, {netip.MustParseAddr("2001:db8::2")}} {
		if ssrvpnDirectFamilyFallback(context.Background(), original, failure, func(context.Context, string) ([]netip.Addr, error) { return answer, nil }) != nil {
			t.Fatal("invented IPv4 mapping")
		}
	}
	if ssrvpnDirectFamilyFallback(context.Background(), original, failure, func(context.Context, string) ([]netip.Addr, error) { return nil, errors.New("DNS failed") }) != nil {
		t.Fatal("DNS failure changed target")
	}
}

func TestSSRVPNDirectIPv4FailureCanUseKnownAAAA(t *testing.T) {
	m := &C.Metadata{DstIP: netip.MustParseAddr("192.0.2.1"), SniffHost: "dual.example", DstPort: 443}
	e := &net.OpError{Op: "dial", Net: "tcp", Err: errors.New("network unreachable")}
	target := ssrvpnDirectFamilyFallback(context.Background(), m, e, func(context.Context, string) ([]netip.Addr, error) {
		return []netip.Addr{netip.MustParseAddr("2001:db8::1")}, nil
	})
	if target == nil || target.Host != "" || !target.DstIP.Is6() || !m.DstIP.Is4() {
		t.Fatal("DIRECT family fallback failed")
	}
}
