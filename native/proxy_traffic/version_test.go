package constant_test

import (
	"strings"
	"testing"

	C "github.com/metacubex/mihomo/constant"
)

func TestSSRVPNCoreVersion(t *testing.T) {
	if !strings.HasSuffix(C.Version, "-ssrvpn.1") {
		t.Fatalf("core version %q does not identify the SSRVPN custom build", C.Version)
	}
}
