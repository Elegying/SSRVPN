package route

import (
	"github.com/metacubex/http"

	"github.com/metacubex/chi/render"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// Registered inside the existing authenticated controller router.
func ssrvpnTraffic(w http.ResponseWriter, r *http.Request) {
	render.JSON(w, r, statistic.ReadProxyTraffic())
}
