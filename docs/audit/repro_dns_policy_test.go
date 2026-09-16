// Copy into dns/ in the exact audited core source. No network requests.
// Mirrors the parent/child policy keys emitted by ClashConfigGenerator;
// resolver addresses are synthetic labels, all loopback.
package dns

import (
	"testing"

	D "github.com/miekg/dns"
)

func TestAuditParentProxyPolicyMustWinChildDirectDNS(t *testing.T) {
	r := NewResolver(Config{Policy: []Policy{
		{Domain: "+.example.com", NameServers: []NameServer{{Net: "udp", Addr: "127.0.0.1:10001"}}},
		{Domain: "+.api.example.com", NameServers: []NameServer{{Net: "udp", Addr: "127.0.0.1:10002"}}},
	}}).Resolver
	q := new(D.Msg)
	q.SetQuestion("api.example.com.", D.TypeA)
	matched := r.matchPolicy(q)
	if len(matched) != 1 {
		t.Fatalf("expected one resolver, got %d", len(matched))
	}
	if got := matched[0].Address(); got != "udp://127.0.0.1:10001" {
		t.Fatalf("traffic rule gives parent PROXY priority, but DNS selected child DIRECT resolver: %s", got)
	}
}
