package outbound

import (
	C "github.com/metacubex/mihomo/constant"
	"net"
	"testing"
)

func TestProxyTrafficUsesOutboundTypeNotNamesOrGroups(t *testing.T) {
	for _, kind := range []C.AdapterType{C.Direct, C.Reject, C.RejectDrop, C.Compatible, C.Pass, C.PassRule, C.Dns, C.Socks5, C.Hysteria2, C.AnyTLS, C.Shadowsocks, C.Vmess} {
		expected := kind >= C.Relay
		// A proxy named DIRECT is still proxied; a renamed direct outbound is not.
		base := NewBase(BaseOption{Name: "DIRECT", Type: kind})
		local, remote := net.Pipe()
		tcp := NewConn(local, base)
		udpSocket, err := net.ListenPacket("udp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		udp := NewPacketConn(udpSocket, base)
		group := NewBase(BaseOption{Name: "selected-node", Type: C.Selector})
		tcp.AppendToChains(group)
		udp.AppendToChains(group)
		if tcp.IsProxy() != expected || udp.IsProxy() != expected {
			t.Fatalf("type %v classification", kind)
		}
		tcp.Close()
		remote.Close()
		udp.Close()
	}
}
