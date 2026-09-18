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

type startupProxyProvider struct {
	P.ProxyProvider
	vehicle P.VehicleType
	started *int
}

func (p startupProxyProvider) VehicleType() P.VehicleType { return p.vehicle }
func (p startupProxyProvider) Initial() error             { *p.started++; return nil }

func TestSSRVPNInlineHealthChecksWaitForTunCommit(t *testing.T) {
	for _, tun := range []bool{false, true} {
		inline, remote := 0, 0
		providers := map[string]P.ProxyProvider{
			"inline": startupProxyProvider{vehicle: P.Compatible, started: &inline},
			"remote": startupProxyProvider{vehicle: P.HTTP, started: &remote},
		}
		prepare, deferred := ssrvpnStartupProviders(providers, tun)
		for _, provider := range prepare {
			_ = provider.Initial()
		}
		if remote != 1 {
			t.Fatal("remote provider unavailable during rule preparation")
		}
		if tun && inline != 0 {
			t.Fatal("inline check opened transport before TUN interface binding")
		}
		if !tun && inline != 1 {
			t.Fatal("system proxy startup changed")
		}
		// ApplyConfig commits TUN and enters OnRunning before loading this set.
		for _, provider := range deferred {
			_ = provider.Initial()
		}
		if inline != 1 || len(providers) != 2 {
			t.Fatal("provider lost or initialized twice")
		}
	}
}
