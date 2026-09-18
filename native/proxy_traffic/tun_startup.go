package executor

import (
	P "github.com/metacubex/mihomo/constant/provider"
	"strings"
)

// The application requires every bundled SSRVPN provider to contain rules.
// A failed file load must not install default routes while the app is waiting
// for readiness. Generic user providers retain upstream empty-list semantics.
func ssrvpnTunRulesReady(providers map[string]P.RuleProvider) bool {
	for name, provider := range providers {
		if strings.HasPrefix(name, "ssrvpn-") && (provider == nil || provider.Count() <= 0) {
			return false
		}
	}
	return true
}

// Inline providers already contain their proxies; Initial only starts health
// checks. In TUN mode defer those checks until physical-interface detection and
// route commit are ready, so reusable transports are not opened unbound first.
// File/HTTP providers keep their preparation order: rules may need their nodes.
func ssrvpnStartupProviders(providers map[string]P.ProxyProvider, tun bool) (prepare, deferred map[string]P.ProxyProvider) {
	if !tun {
		return providers, nil
	}
	prepare = make(map[string]P.ProxyProvider)
	deferred = make(map[string]P.ProxyProvider)
	for name, provider := range providers {
		if provider.VehicleType() == P.Compatible {
			deferred[name] = provider
		} else {
			prepare[name] = provider
		}
	}
	return
}
