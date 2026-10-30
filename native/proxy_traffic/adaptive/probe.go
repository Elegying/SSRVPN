package adaptive

import (
	"context"
	"crypto/tls"
	"encoding/base64"
	"io"
	"net"
	"net/http"
	"time"
)

type Dial func(context.Context, string) (net.Conn, error)
type Packet func(context.Context) (net.PacketConn, error)

// Literal destinations force the remote exit family; TLS and a valid DNS reply
// prove more than a transport handshake. Probes never use OS HTTP proxies.
func Probe(ctx context.Context, dial Dial, packet Packet) Sample {
	type answer struct {
		family int
		udp    bool
		ok     bool
	}
	results := make(chan answer, 6)
	for _, target := range []struct {
		ip, host string
		family   int
	}{
		{"2606:4700:4700::1111", "cloudflare-dns.com", 6},
		{"2001:4860:4860::8888", "dns.google", 6},
		{"1.1.1.1", "cloudflare-dns.com", 4},
	} {
		target := target
		go func() { results <- answer{target.family, false, probeHTTPS(ctx, dial, target.ip, target.host)} }()
		go func() { results <- answer{target.family, true, probeUDP(ctx, packet, target.ip)} }()
	}
	var sample, datagrams Sample
	for i := 0; i < 6; i++ {
		select {
		case r := <-results:
			result := &sample
			if r.udp {
				result = &datagrams
			}
			if r.family == 4 {
				result.IPv4 = r.ok
			} else {
				result.IPv6 = result.IPv6 || r.ok
			}
		case <-ctx.Done():
			return Sample{}
		}
	}
	return Sample{IPv4: sample.IPv4 && datagrams.IPv4, IPv6: sample.IPv6 && datagrams.IPv6}
}

func probeHTTPS(parent context.Context, dial Dial, ip, host string) bool {
	ctx, cancel := context.WithTimeout(parent, 4*time.Second)
	defer cancel()
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return dial(ctx, net.JoinHostPort(ip, "443"))
		},
		TLSClientConfig:     &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout: 3 * time.Second, DisableKeepAlives: true,
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 4 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	// Fixed, credential-free DNS A query for example.com; no browsing data leaves.
	query := []byte{0x53, 0x56, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0, 0, 1, 0, 1}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://"+host+"/dns-query?dns="+base64.RawURLEncoding.EncodeToString(query), nil)
	if err != nil {
		return false
	}
	request.Header.Set("Accept", "application/dns-message")
	response, err := client.Do(request)
	if err != nil {
		return false
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return false
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 4097))
	return err == nil && len(data) >= len(query) && len(data) <= 4096 && data[0] == query[0] && data[1] == query[1] && data[2]&0x80 != 0 && data[3]&15 == 0 && (data[6] != 0 || data[7] != 0)
}

func probeUDP(parent context.Context, packet Packet, ip string) bool {
	ctx, cancel := context.WithTimeout(parent, 4*time.Second)
	defer cancel()
	conn, err := packet(ctx)
	if err != nil {
		return false
	}
	defer conn.Close()
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			conn.Close()
		case <-done:
		}
	}()
	if err = conn.SetReadDeadline(time.Now().Add(4 * time.Second)); err != nil {
		return false
	}
	target := &net.UDPAddr{IP: net.ParseIP(ip), Port: 53}
	query := []byte{0x53, 0x56, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0, 0, 1, 0, 1}
	if _, err = conn.WriteTo(query, target); err != nil {
		return false
	}
	data := make([]byte, 4097)
	n, from, err := conn.ReadFrom(data)
	if err != nil || from == nil || n < len(query) || n > 4096 {
		return false
	}
	host, port, err := net.SplitHostPort(from.String())
	return err == nil && port == "53" && net.ParseIP(host).Equal(target.IP) && data[0] == query[0] && data[1] == query[1] && data[2]&0x80 != 0 && data[3]&15 == 0 && (data[6] != 0 || data[7] != 0)
}
