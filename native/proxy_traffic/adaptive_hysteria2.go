package outbound

import (
	"context"
	"encoding/json"
	"net"
	"net/netip"
	"path/filepath"

	"github.com/metacubex/mihomo/component/adaptive"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	M "github.com/metacubex/sing/common/metadata"
)

func (h *Hysteria2) ssrvpnAdaptiveController() *adaptive.Controller {
	h.egressOnce.Do(func() {
		// All options participate: accounts/certificates and changed subscription
		// endpoints never borrow one another's cached diagnosis. Only a hash is saved.
		identity, err := json.Marshal(h.option)
		directory := filepath.Join(C.Path.HomeDir(), "egress-capabilities")
		if err != nil {
			directory = ""
		} // Runtime-only injected dialers are not persistable identities.
		h.egress = adaptive.New(string(identity), directory, func(ctx context.Context) adaptive.Sample {
			return adaptive.Probe(ctx, func(ctx context.Context, address string) (net.Conn, error) {
				return h.client.DialConn(ctx, M.ParseSocksaddr(address))
			}, h.client.ListenPacket)
		})
	})
	return h.egress
}

func (h *Hysteria2) ssrvpnAdaptiveTarget(ctx context.Context, original *C.Metadata, udp bool) (*C.Metadata, error) {
	// Explicit operator restrictions remain stronger than automatic recovery.
	if h.option.SSRVPNEgress == "ipv4" {
		return ssrvpnEgressTarget(ctx, original, "ipv4", udp, resolver.ResolveIPv4)
	}
	state := h.ssrvpnAdaptiveController().Observe()
	if !state.Verified || !state.IPv4Only {
		return original, nil
	}
	target := original.Clone()
	// These are fixed paired DNS services, not arbitrary IPv6 address translation.
	if target.DNSMode != C.DNSHosts && (target.DstPort == 443 || target.DstPort == 853 || target.DstPort == 53) {
		host := target.Host
		if host == "" {
			host = target.DstIP.String()
		}
		pairs := map[string]string{"2606:4700:4700::1111": "1.1.1.1", "2606:4700:4700::1001": "1.0.0.1", "2001:4860:4860::8888": "8.8.8.8", "2001:4860:4860::8844": "8.8.4.4"}
		if address, ok := pairs[host]; ok {
			target.Host = ""
			target.DstIP = netip.MustParseAddr(address)
			return target, nil
		}
	}
	// Resolve A through the existing selected-node DNS route for TCP as well as
	// UDP. The operator-only path historically left TCP DNS to the server.
	target, err := ssrvpnEgressTarget(ctx, target, "ipv4", true, resolver.ResolveIPv4)
	if err != nil {
		return nil, err
	}
	if target.DstIP.Is4() {
		target.Host = ""
	}
	return target, nil
}
