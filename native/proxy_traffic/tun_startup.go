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
