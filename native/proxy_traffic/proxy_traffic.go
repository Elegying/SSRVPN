package statistic

import (
	"sync/atomic"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

// Each tracker holds its session so late closes/writes from a retired Android
// session cannot add bytes to the next connection. No per-connection history is kept.
type proxyTrafficSession struct {
	generation int64
	upload     atomic.Int64
	download   atomic.Int64
}

var proxyTrafficClock = time.Now()
var proxyTrafficGeneration atomic.Int64
var activeProxyTraffic atomic.Pointer[proxyTrafficSession]

func init() {
	proxyTrafficGeneration.Store(time.Now().UnixNano())
	BeginProxyTrafficSession()
}

func BeginProxyTrafficSession() {
	activeProxyTraffic.Store(&proxyTrafficSession{generation: proxyTrafficGeneration.Add(1)})
}

func CaptureProxyTrafficSession() *proxyTrafficSession { return activeProxyTraffic.Load() }

func proxySessionFor(conn C.Connection, counted bool, sessions []*proxyTrafficSession) *proxyTrafficSession {
	if !counted || !conn.IsProxy() {
		return nil
	}
	if len(sessions) != 0 {
		return sessions[0]
	}
	return activeProxyTraffic.Load()
}

type ProxyTrafficSnapshot struct {
	SessionGeneration int64 `json:"sessionGeneration"`
	SampledAtMillis   int64 `json:"sampledAtMillis"`
	Upload            int64 `json:"upload"`
	Download          int64 `json:"download"`
}

func ReadProxyTraffic() ProxyTrafficSnapshot {
	session := activeProxyTraffic.Load()
	return ProxyTrafficSnapshot{
		SessionGeneration: session.generation,
		SampledAtMillis:   time.Since(proxyTrafficClock).Milliseconds(),
		Upload:            session.upload.Load(),
		Download:          session.download.Load(),
	}
}
