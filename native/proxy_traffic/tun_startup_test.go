package executor

import (
	P "github.com/metacubex/mihomo/constant/provider"
	"testing"
)

type startupRuleProvider struct {
	P.RuleProvider
	count int
}

func (p startupRuleProvider) Count() int { return p.count }

func TestSSRVPNTunCaptureRequiresPreparedRules(t *testing.T) {
	providers := map[string]P.RuleProvider{
		"ssrvpn-geosite-cn":  startupRuleProvider{count: 12},
		"ssrvpn-geosite-gfw": startupRuleProvider{count: 0},
	}
	if ssrvpnTunRulesReady(providers) {
		t.Fatal("empty required rules allowed capture")
	}
	providers["ssrvpn-geosite-gfw"] = startupRuleProvider{count: 20}
	if !ssrvpnTunRulesReady(providers) {
		t.Fatal("ready rules blocked capture")
	}
	providers["ssrvpn-geosite-cn"] = nil
	if ssrvpnTunRulesReady(providers) {
		t.Fatal("missing required provider allowed capture")
	}
	if !ssrvpnTunRulesReady(map[string]P.RuleProvider{"optional-user-list": startupRuleProvider{}}) {
		t.Fatal("unrelated empty provider semantics changed")
	}
}
