package outbound

import (
	"context"
	"net/netip"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/adaptive"
	C "github.com/metacubex/mihomo/constant"
)

func TestSSRVPNAdaptiveTargetBoundaries(t *testing.T) {
	h := &Hysteria2{option: &Hysteria2Option{}}
	h.egressOnce.Do(func() {
		h.egress = adaptive.New("test", "", func(context.Context) adaptive.Sample { return adaptive.Sample{IPv4: true} })
	})
	defer h.egress.Close()
	h.egress.Check(context.Background()) // Establish a verified IPv4-only exit.
	for _, udp := range []bool{false, true} {
		for _, port := range []uint16{53, 443, 853} {
			original := &C.Metadata{DstIP: netip.MustParseAddr("2606:4700:4700::1111"), DstPort: port}
			result, err := h.ssrvpnAdaptiveTarget(context.Background(), original, udp)
			if err != nil || result.DstIP.String() != "1.1.1.1" || result.Host != "" {
				t.Fatalf("paired DNS failed: %v %v", result, err)
			}
			if !original.DstIP.Is6() {
				t.Fatal("mutated caller metadata")
			}
			pinned := original.Clone()
			pinned.DNSMode = C.DNSHosts
			if _, err = h.ssrvpnAdaptiveTarget(context.Background(), pinned, udp); err == nil {
				t.Fatal("overrode explicit hosts")
			}
		}
		literal := &C.Metadata{DstIP: netip.MustParseAddr("2001:db8::1"), DstPort: 443}
		if _, err := h.ssrvpnAdaptiveTarget(context.Background(), literal, udp); err == nil {
			t.Fatal("invented translation for literal IPv6")
		}
		v4 := &C.Metadata{DstIP: netip.MustParseAddr("192.0.2.1"), DstPort: 443}
		result, err := h.ssrvpnAdaptiveTarget(context.Background(), v4, udp)
		if err != nil || result.DstIP != v4.DstIP {
			t.Fatal("broke IPv4 flow", err)
		}
	}
}

func TestSSRVPNAdaptiveHealthyNodePreservesTarget(t *testing.T) {
	h := &Hysteria2{option: &Hysteria2Option{}}
	h.egressOnce.Do(func() {
		h.egress = adaptive.New("test", "", func(context.Context) adaptive.Sample { return adaptive.Sample{IPv6: true} })
	})
	defer h.egress.Close()
	if s := h.egress.Check(context.Background()); !s.Verified || s.IPv4Only {
		t.Fatal("healthy exit not established", s)
	}
	original := &C.Metadata{Host: "example.test", DstIP: netip.MustParseAddr("2001:db8::1"), DstPort: 443}
	result, err := h.ssrvpnAdaptiveTarget(context.Background(), original, false)
	if err != nil || result != original {
		t.Fatal("healthy node target changed", err)
	}
}

func TestSSRVPNAdaptiveInitialFlowDoesNotWaitForProbe(t *testing.T) {
	h := &Hysteria2{option: &Hysteria2Option{}}
	entered := make(chan struct{})
	h.egressOnce.Do(func() {
		h.egress = adaptive.New("test", "", func(ctx context.Context) adaptive.Sample {
			close(entered)
			<-ctx.Done()
			return adaptive.Sample{}
		})
	})
	defer h.egress.Close()
	original := &C.Metadata{Host: "example.test", DstPort: 443}
	done := make(chan struct{})
	go func() {
		defer close(done)
		result, err := h.ssrvpnAdaptiveTarget(context.Background(), original, false)
		if err != nil || result != original {
			t.Error("unverified probe altered first flow", err)
		}
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("first flow blocked behind diagnostics")
	}
	<-entered
}
