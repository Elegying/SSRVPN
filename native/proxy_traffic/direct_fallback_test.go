package outbound

import (
	"context"
	"errors"
	"github.com/metacubex/mihomo/component/iface"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"io"
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

// Exercise native DIRECT sockets, not a mocked success from the selector.
type ssrvpnDirectResolverFixture struct {
	resolver.Resolver
	ips []netip.Addr
}

func (r ssrvpnDirectResolverFixture) Invalid() bool { return true }
func (r ssrvpnDirectResolverFixture) LookupIP(context.Context, string) ([]netip.Addr, error) {
	return r.ips, nil
}

func TestSSRVPNMappedDirectUDPUsesNativeIPv4AndIPv6Resolution(t *testing.T) {
	oldDisabled, oldResolver := resolver.DisableIPv6, resolver.DirectHostResolver
	resolver.DisableIPv6 = false
	defer func() { resolver.DisableIPv6, resolver.DirectHostResolver = oldDisabled, oldResolver }()
	for _, address := range []string{"127.0.0.1:0", "[::1]:0"} {
		t.Run(address, func(t *testing.T) {
			server, err := net.ListenPacket("udp", address)
			if err != nil {
				t.Fatal(err)
			}
			defer server.Close()
			local := server.LocalAddr().(*net.UDPAddr).AddrPort()
			ips := []netip.Addr{local.Addr()}
			if local.Addr().Is4() {
				ips = append([]netip.Addr{netip.MustParseAddr("2001:db8::1")}, ips...)
			}
			resolver.DirectHostResolver = ssrvpnDirectResolverFixture{ips: ips}
			original := &C.Metadata{Host: "mapped.synthetic.invalid", DstIP: netip.MustParseAddr("2001:db8::1"), DNSMode: C.DNSMapping, NetWork: C.UDP, DstPort: local.Port()}
			target := original.Clone()
			target.DstIP = netip.Addr{} // target selector contract is tested in tunnel
			target = target.Pure()
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			conn, err := NewDirect().ListenPacketContext(ctx, target)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			if target.DstIP != local.Addr() {
				t.Fatalf("wrong native address choice: %v", target.DstIP)
			}
			if _, err = conn.WriteTo([]byte("datagram"), target.UDPAddr()); err != nil {
				t.Fatal(err)
			}
			server.SetReadDeadline(time.Now().Add(time.Second))
			data := make([]byte, 32)
			n, source, err := server.ReadFrom(data)
			if err != nil || string(data[:n]) != "datagram" {
				t.Fatalf("DIRECT packet not delivered: %v", err)
			}
			if _, err = server.WriteTo(data[:n], source); err != nil {
				t.Fatal(err)
			}
			conn.SetReadDeadline(time.Now().Add(time.Second))
			n, _, err = conn.ReadFrom(data)
			if err != nil || string(data[:n]) != "datagram" {
				t.Fatalf("DIRECT reply not delivered: %v", err)
			}
		})
	}
}

func TestSSRVPNMappedDirectTCPUsesNativeRace(t *testing.T) {
	oldDisabled, oldResolver := resolver.DisableIPv6, resolver.DirectHostResolver
	resolver.DisableIPv6 = false
	defer func() { resolver.DisableIPv6, resolver.DirectHostResolver = oldDisabled, oldResolver }()
	server, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	go func() {
		conn, err := server.Accept()
		if err == nil {
			defer conn.Close()
			conn.Write([]byte("response"))
		}
	}()
	// Use an unavailable loopback family. A documentation-range IPv6 address
	// can be accepted by a real TUN on the test host, making the dial appear
	// successful before its remote failure and invalidating this local fixture.
	resolver.DirectHostResolver = ssrvpnDirectResolverFixture{ips: []netip.Addr{netip.MustParseAddr("::1"), netip.MustParseAddr("127.0.0.1")}}
	original := &C.Metadata{Host: "mapped.synthetic.invalid", DstIP: netip.MustParseAddr("2001:db8::1"), DNSMode: C.DNSMapping, NetWork: C.TCP, DstPort: uint16(server.Addr().(*net.TCPAddr).Port)}
	target := original.Clone()
	target.DstIP = netip.Addr{} // target selector contract is tested in tunnel
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	conn, err := NewDirect().DialContext(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetReadDeadline(time.Now().Add(time.Second))
	payload, err := io.ReadAll(conn)
	if err != nil || string(payload) != "response" {
		t.Fatalf("native family race did not deliver payload: %v", err)
	}
}

func TestSSRVPNPhysicalIPv4OnlyDoesNotInventInternetReachability(t *testing.T) {
	for _, tc := range []struct {
		name      string
		addresses []string
		only4     bool
	}{
		{"IPv4 only", []string{"192.0.2.1/24"}, true},
		{"link-local is not IPv6 Internet", []string{"192.0.2.1/24", "fe80::1/64"}, true},
		{"dual is unknown, not proven Internet", []string{"192.0.2.1/24", "2001:db8::1/64"}, false},
		{"ULA may have local/NAT connectivity", []string{"192.0.2.1/24", "fd00::1/64"}, false},
		{"IPv6 only", []string{"2001:db8::1/64"}, false},
		{"no addresses", nil, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			i := &iface.Interface{Flags: net.FlagUp}
			for _, prefix := range tc.addresses {
				i.Addresses = append(i.Addresses, netip.MustParsePrefix(prefix))
			}
			if ssrvpnPhysicalIPv4Only(i) != tc.only4 {
				t.Fatal("incorrect physical source classification")
			}
			i.Flags = 0
			if ssrvpnPhysicalIPv4Only(i) {
				t.Fatal("down interface was usable")
			}
		})
	}
	if ssrvpnPhysicalIPv4Only(nil) {
		t.Fatal("missing interface became a capability verdict")
	}
}

type ssrvpnPartialDNSFixture struct {
	resolver.Resolver
	a     []netip.Addr
	aErr  error
	calls int
}

func (r *ssrvpnPartialDNSFixture) LookupIPv4(ctx context.Context, _ string) ([]netip.Addr, error) {
	r.calls++
	return r.a, r.aErr
}
func (r *ssrvpnPartialDNSFixture) LookupIP(context.Context, string) ([]netip.Addr, error) {
	return []netip.Addr{netip.MustParseAddr("2001:db8::1")}, nil
}

func TestSSRVPNIPv4SourceDoesNotLoseLateAOrDisableAAAA(t *testing.T) {
	source := &ssrvpnPartialDNSFixture{a: []netip.Addr{netip.MustParseAddr("192.0.2.1")}}
	r := ssrvpnIPv4SourceResolver{source}
	ips, err := r.LookupIP(context.Background(), "dual.synthetic.invalid")
	if err != nil || len(ips) != 1 || !ips[0].Is4() || source.calls != 1 {
		t.Fatal("early AAAA hid available A")
	}
	source.a = nil
	ips, err = r.LookupIP(context.Background(), "v6.synthetic.invalid")
	if err != nil || len(ips) != 1 || !ips[0].Is6() {
		t.Fatal("IPv6-only target was filtered or invented")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = r.LookupIP(ctx, "cancel.synthetic.invalid"); !errors.Is(err, context.Canceled) {
		t.Fatal("cancellation lost")
	}
}
