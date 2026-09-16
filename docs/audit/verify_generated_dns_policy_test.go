// Copy to dns/ of the pinned macOS core and set SSRVPN_DNS_POLICY_FIXTURE
// to JSON from export_rule_dns_fixture.dart. This does not issue DNS requests.
package dns

import (
	"encoding/json"
	D "github.com/miekg/dns"
	"os"
	"strings"
	"testing"
)

func TestSSRVPNGeneratedParentProxyDNS(t *testing.T) {
	data, err := os.ReadFile(os.Getenv("SSRVPN_DNS_POLICY_FIXTURE"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		ParentProxyIndex int      `json:"parentProxyIndex"`
		ChildDirectIndex int      `json:"childDirectIndex"`
		ParentDNS        []string `json:"parentDns"`
		ChildDNS         []string `json:"childDns"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if fixture.ParentProxyIndex >= fixture.ChildDirectIndex {
		t.Fatal("invalid traffic precedence")
	}
	var policies []Policy
	for domain, servers := range map[string][]string{
		"+.example.com":     fixture.ParentDNS,
		"+.api.example.com": fixture.ChildDNS,
	} {
		if len(servers) == 0 {
			continue
		}
		address := "127.0.0.1:10002"
		if strings.HasSuffix(servers[0], "#PROXY") {
			address = "127.0.0.1:10001"
		}
		policies = append(policies, Policy{Domain: domain,
			NameServers: []NameServer{{Net: "udp", Addr: address}}})
	}
	resolver := NewResolver(Config{Policy: policies}).Resolver
	for _, host := range []string{"example.com.", "api.example.com.", "deep.api.example.com."} {
		question := new(D.Msg)
		question.SetQuestion(host, D.TypeA)
		matched := resolver.matchPolicy(question)
		if len(matched) != 1 || matched[0].Address() != "udp://127.0.0.1:10001" {
			t.Fatalf("generated DNS policy conflicts with parent PROXY rule for %s", host)
		}
	}
}
