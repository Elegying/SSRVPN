package config_test

import (
	"fmt"
	"github.com/metacubex/mihomo/config"
	_ "github.com/metacubex/mihomo/hub/executor"
	"testing"
)

// Run unchanged on each pinned source version. Parsing never installs a TUN
// interface or changes the host network. Reachability is tested separately.
func TestSSRVPNDualStackConfigVersionMatrix(t *testing.T) {
	for _, server := range []string{"192.0.2.1", "2001:db8::1", "node.synthetic.invalid"} {
		for _, stack := range []string{"gvisor", "system", "mixed"} {
			for _, enabled := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/%s/tun=%t", server, stack, enabled), func(t *testing.T) {
					text := fmt.Sprintf(`
ipv6: true
mode: rule
dns:
  enable: true
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-range6: fdfe:dcba:9877::/64
  nameserver: [223.5.5.5]
tun:
  enable: %t
  stack: %s
  auto-route: true
  auto-detect-interface: true
  inet6-address: [fdfe:dcba:9876::1/126]
proxies:
  - {name: fixture, type: ss, server: "%s", port: 443, cipher: aes-128-gcm, password: synthetic}
proxy-groups:
  - {name: PROXY, type: select, proxies: [fixture]}
rules:
  - DOMAIN-SUFFIX,forced.synthetic.invalid,PROXY
  - IP-CIDR6,2001:db8::2/128,PROXY,no-resolve
  - DOMAIN-SUFFIX,cn,DIRECT
  - MATCH,PROXY
`, enabled, stack, server)
					cfg, err := config.Parse([]byte(text))
					if err != nil {
						t.Fatal(err)
					}
					if !cfg.DNS.FakeIPRange6.IsValid() || !cfg.DNS.FakeIPRange.IsValid() || !cfg.DNS.IPv6 {
						t.Fatal("both DNS families must survive configuration parsing")
					}
					if len(cfg.General.Tun.Inet6Address) == 0 {
						t.Fatal("IPv6 capture lost")
					}
				})
			}
		}
	}
}
