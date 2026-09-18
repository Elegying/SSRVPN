package tunnel

import (
	"context"
	"io"
	"net/netip"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/common/lru"
	N "github.com/metacubex/mihomo/common/net"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/sing/common/buf"
)

// A short-lived, bounded preference for one node + destination, not a node-wide
// capability verdict. Only actual response bytes teach it; DialContext success
// alone says nothing about remote reachability for SS/Trojan/QUIC transports.
type ssrvpnFamilyKey struct {
	node, endpoint, host string
	port                 uint16
	network              C.NetWork
}

var ssrvpnWorkingFamily = lru.New[ssrvpnFamilyKey, bool](
	lru.WithSize[ssrvpnFamilyKey, bool](256), lru.WithAge[ssrvpnFamilyKey, bool](60))

func ssrvpnFamilyCacheKey(metadata *C.Metadata, proxy C.Proxy) (ssrvpnFamilyKey, bool) {
	host := metadata.Host
	if host == "" {
		host = metadata.SniffHost
	}
	if host == "" || metadata.Type == C.INNER || metadata.DNSMode == C.DNSHosts {
		return ssrvpnFamilyKey{}, false
	}
	for depth := 0; depth < 16; depth++ {
		next := proxy.Unwrap(metadata, false)
		if next == nil {
			switch proxy.Type() {
			case C.Direct, C.Reject, C.RejectDrop, C.Compatible, C.Pass, C.PassRule, C.Dns:
				return ssrvpnFamilyKey{}, false
			}
			return ssrvpnFamilyKey{proxy.Name(), proxy.Addr(), host, metadata.DstPort, metadata.NetWork}, true
		}
		proxy = next
	}
	return ssrvpnFamilyKey{}, false
}

type ssrvpnFamilyConn struct {
	C.Conn
	received atomic.Bool
	key      ssrvpnFamilyKey
	ipv6     bool
}

func (c *ssrvpnFamilyConn) observed(n int64) {
	if n > 0 && c.received.CompareAndSwap(false, true) {
		ssrvpnWorkingFamily.Set(c.key, c.ipv6)
	}
}
func (c *ssrvpnFamilyConn) Close() error {
	if !c.received.Load() {
		if ipv6, found := ssrvpnWorkingFamily.Get(c.key); found && ipv6 == c.ipv6 {
			ssrvpnWorkingFamily.Delete(c.key)
		}
	}
	return c.Conn.Close()
}
func (c *ssrvpnFamilyConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	c.observed(int64(n))
	return n, err
}
func (c *ssrvpnFamilyConn) ReadBuffer(b *buf.Buffer) error {
	err := c.Conn.ReadBuffer(b)
	c.observed(int64(b.Len()))
	return err
}

// Preserve the core's optimized copy path; observation adds no data buffering.
func (c *ssrvpnFamilyConn) UnwrapReader() (io.Reader, []N.CountFunc) {
	return c.Conn, []N.CountFunc{c.observed}
}
func (c *ssrvpnFamilyConn) UnwrapWriter() (io.Writer, []N.CountFunc) { return c.Conn, nil }

func ssrvpnObserveWorkingFamily(conn C.Conn, original, dial *C.Metadata, proxy C.Proxy) C.Conn {
	key, ok := ssrvpnFamilyCacheKey(original, proxy)
	if !ok || !dial.DstIP.IsValid() || !conn.IsProxy() || len(conn.Chains()) == 0 || conn.Chains()[0] != key.node {
		return conn
	}
	return &ssrvpnFamilyConn{Conn: conn, key: key, ipv6: dial.DstIP.Is6()}
}

// A transport may have sent bytes even when its Write reports an error. Once
// application payload was offered, retrying another destination could replay a
// non-idempotent request. A header-only handshake is still safe to retry.
type ssrvpnPayloadWriteError struct{ error }

func (e *ssrvpnPayloadWriteError) Unwrap() error { return e.error }

func ssrvpnWriteInitialPayload(remote io.Writer, payload []byte) error {
	written, err := remote.Write(payload)
	if err == nil && written != len(payload) {
		err = io.ErrShortWrite
	}
	if err != nil && len(payload) > 0 {
		return &ssrvpnPayloadWriteError{err}
	}
	return err
}

// Apply only after routing. Proxy-server addresses and internal DNS transports
// keep their own resolver: resolving those here would recurse through DNS.
func ssrvpnProxyTargetCandidates(ctx context.Context, metadata *C.Metadata, proxy C.Proxy) []*C.Metadata {
	if resolver.DisableIPv6 || metadata.Type == C.INNER || metadata.DNSMode == C.DNSHosts {
		return []*C.Metadata{metadata.Pure()}
	}
	for depth := 0; depth < 16; depth++ {
		next := proxy.Unwrap(metadata, false)
		if next == nil {
			switch proxy.Type() {
			case C.Direct:
				// Restore only a DNS-cache mapping, after the route is selected.
				// Pure would otherwise pin the mapped AAAA and hide the domain
				// from native TCP Happy Eyeballs and DIRECT UDP's A selection.
				// Clearing DstIP also survives the UDP caller's second Pure().
				if metadata.DNSMode == C.DNSMapping && metadata.Host != "" && metadata.DstIP.Is6() {
					if node, _ := resolver.DefaultHosts.Search(metadata.Host, false); node == nil {
						target := metadata.Clone()
						target.DstIP = netip.Addr{}
						return []*C.Metadata{target}
					}
				}
				fallthrough
			case C.Reject, C.RejectDrop, C.Compatible, C.Pass, C.PassRule, C.Dns:
				target := metadata.Pure()
				if metadata.DNSMode == C.DNSMapping && metadata.Host != "" && target.SniffHost == "" {
					target = target.Clone()
					target.SniffHost = metadata.Host
				}
				return []*C.Metadata{target}
			}
			if target := ssrvpnRemoteDomainTarget(metadata, proxy.Type()); target != nil {
				return []*C.Metadata{target}
			}
			candidates := ssrvpnTargetCandidates(ctx, metadata, resolver.LookupIP)
			if key, ok := ssrvpnFamilyCacheKey(metadata, proxy); ok {
				if ipv6, found := ssrvpnWorkingFamily.Get(key); found {
					return ssrvpnPreferWorkingFamily(candidates, ipv6)
				}
			}
			return candidates
		}
		proxy = next
	}
	return []*C.Metadata{metadata.Pure()}
}

// These protocols do not reliably acknowledge remote target establishment
// before application writes. Pinning a local A/AAAA choice makes safe fallback
// impossible after a successful transport handshake. Preserve the domain so
// the selected proxy server can use its own reachable families, as the native
// adapters already support. Never change literal targets or explicit hosts.
func ssrvpnRemoteDomainTarget(metadata *C.Metadata, kind C.AdapterType) *C.Metadata {
	if metadata.NetWork != C.TCP || metadata.DNSMode == C.DNSHosts || metadata.Type == C.INNER {
		return nil
	}
	switch kind {
	case C.Shadowsocks, C.ShadowsocksR, C.Trojan, C.Vmess, C.Vless, C.Hysteria, C.Hysteria2, C.Tuic, C.AnyTLS:
	default:
		return nil
	}
	host := metadata.Host
	if host == "" {
		host = metadata.SniffHost
	}
	if host == "" {
		return nil
	}
	if _, err := netip.ParseAddr(host); err == nil {
		return nil
	}
	target := metadata.Clone()
	target.Host = host
	target.DstIP = netip.Addr{}
	return target
}

func ssrvpnPreferWorkingFamily(candidates []*C.Metadata, ipv6 bool) []*C.Metadata {
	ordered := make([]*C.Metadata, 0, len(candidates))
	for _, preferred := range []bool{true, false} {
		for _, target := range candidates {
			if target.Host == "" && target.DstIP.IsValid() && (target.DstIP.Is6() == ipv6) == preferred {
				ordered = append(ordered, target)
			}
		}
	}
	for _, target := range candidates {
		if target.Host != "" || !target.DstIP.IsValid() {
			ordered = append(ordered, target)
		}
	}
	return ordered
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
	lookupCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	ips, err := lookup(lookupCtx, host)
	if err != nil || len(ips) == 0 {
		// Remote DNS through the already selected proxy remains available. Never
		// fall back to DIRECT or turn a transient DNS failure into a disconnection.
		return []*C.Metadata{metadata}
	}
	// A previously resolved IPv4 is not proof that AAAA is absent. This occurs
	// after DNS mapping/sniffing too; keep it without dropping other candidates.
	if metadata.DstIP.IsValid() && !resolver.IsFakeIP(metadata.DstIP) {
		ips = append([]netip.Addr{metadata.DstIP}, ips...)
	}
	candidates := make([]*C.Metadata, 0, 9)
	var families [2][]*C.Metadata
	seen := make(map[netip.Addr]bool)
	for family, ipv4 := range []bool{true, false} {
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
			families[family] = append(families[family], next)
			count++
			if count == 4 {
				break
			}
		}
	}
	// Interleave families so several unavailable A records cannot starve AAAA
	// within the common connection deadline. Successful responses can reorder it.
	for index := 0; index < 4; index++ {
		for _, family := range families {
			if index < len(family) {
				candidates = append(candidates, family[index])
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
