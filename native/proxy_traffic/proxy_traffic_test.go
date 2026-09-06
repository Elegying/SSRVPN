package statistic

import (
	"io"
	"net"
	"sync"
	"testing"

	"github.com/metacubex/mihomo/common/buf"
	C "github.com/metacubex/mihomo/constant"
)

type trafficConn struct {
	C.Conn
	proxy bool
}

func (c trafficConn) IsProxy() bool             { return c.proxy }
func (trafficConn) Chains() C.Chain             { return C.Chain{"arbitrary-name"} }
func (trafficConn) ProviderChains() C.Chain     { return nil }
func (trafficConn) RemoteDestination() string   { return "127.0.0.1" }
func (trafficConn) Read(b []byte) (int, error)  { return copy(b, "down"), io.EOF }
func (trafficConn) Write(b []byte) (int, error) { return len(b), nil }
func (trafficConn) Close() error                { return nil }
func (trafficConn) ReadBuffer(b *buf.Buffer) error {
	b.Write([]byte("buffer"))
	return io.EOF
}
func (trafficConn) WriteBuffer(b *buf.Buffer) error { b.Release(); return nil }

type partialTrafficConn struct{ trafficConn }

func (partialTrafficConn) Write([]byte) (int, error) { return 2, io.ErrShortWrite }

func TestProxyTrafficBuffersAndPartialTransfers(t *testing.T) {
	BeginProxyTrafficSession()
	for _, proxy := range []bool{true, false} {
		tracker := NewTCPTracker(partialTrafficConn{trafficConn{proxy: proxy}}, &Manager{}, &C.Metadata{}, nil, 0, 0, true)
		tracker.Write([]byte("partially written"))
		tracker.WriteBuffer(buf.As([]byte("upload")))
		buffer := buf.New()
		tracker.ReadBuffer(buffer)
		buffer.Release()
		tracker.Close()
	}
	if got := ReadProxyTraffic(); got.Upload != 8 || got.Download != 6 {
		t.Fatalf("buffer/partial transfer totals: %+v", got)
	}
}

type trafficPacket struct {
	C.PacketConn
	trafficConn
}

func (p trafficPacket) IsProxy() bool                             { return p.proxy }
func (p trafficPacket) Chains() C.Chain                           { return p.trafficConn.Chains() }
func (p trafficPacket) ProviderChains() C.Chain                   { return nil }
func (p trafficPacket) RemoteDestination() string                 { return "127.0.0.1" }
func (p trafficPacket) AppendToChains(C.ProxyAdapter)             {}
func (p trafficPacket) Close() error                              { return nil }
func (p trafficPacket) ReadFrom(b []byte) (int, net.Addr, error)  { return copy(b, "packet"), nil, nil }
func (p trafficPacket) WriteTo(b []byte, _ net.Addr) (int, error) { return len(b), nil }
func (p trafficPacket) WaitReadFrom() ([]byte, func(), net.Addr, error) {
	return []byte("packet"), func() {}, nil, nil
}

func TestProxyTrafficShortConnectionsAndExclusions(t *testing.T) {
	BeginProxyTrafficSession()
	manager := &Manager{}
	for _, c := range []struct{ proxy, counted bool }{{true, true}, {false, true}, {true, false}} {
		tracker := NewTCPTracker(trafficConn{proxy: c.proxy}, manager, &C.Metadata{}, nil, 3, 2, c.counted)
		tracker.Write([]byte("up"))
		tracker.Read(make([]byte, 10))
		_, writers := tracker.UnwrapWriter()
		writers[0](7)
		_, readers := tracker.UnwrapReader()
		readers[0](8)
		tracker.Close()
	}
	sample := ReadProxyTraffic()
	if sample.Upload != 12 || sample.Download != 14 {
		t.Fatalf("proxy totals: %+v", sample)
	}
	// Existing global counters retain both direct and proxy traffic.
	up, down := manager.Total()
	if up != 24 || down != 28 {
		t.Fatalf("global totals changed: %d/%d", up, down)
	}
	if len(manager.Snapshot().Connections) != 0 {
		t.Fatal("closed connections retained")
	}
}

func TestProxyTrafficUDPAndRetiredSession(t *testing.T) {
	BeginProxyTrafficSession()
	oldSession := CaptureProxyTrafficSession()
	old := NewTCPTracker(trafficConn{proxy: true}, &Manager{}, &C.Metadata{}, nil, 0, 0, true, oldSession)
	old.Write([]byte("old"))
	before := ReadProxyTraffic()
	BeginProxyTrafficSession()
	// Both an already-open connection and a dial completing late keep their old session.
	old.Write([]byte("late"))
	delayed := NewTCPTracker(trafficConn{proxy: true}, &Manager{}, &C.Metadata{}, nil, 9, 9, true, oldSession)
	delayed.Close()
	old.Close()
	for _, proxy := range []bool{true, false} {
		packet := NewUDPTracker(trafficPacket{trafficConn: trafficConn{proxy: proxy}}, &Manager{}, &C.Metadata{}, nil, 1, 2, true)
		packet.WriteTo([]byte("upload"), nil)
		packet.ReadFrom(make([]byte, 12))
		packet.WaitReadFrom()
		packet.Close()
	}
	after := ReadProxyTraffic()
	if before.SessionGeneration == after.SessionGeneration || after.Upload != 7 || after.Download != 14 {
		t.Fatalf("new session: %+v", after)
	}
}

func TestProxyTrafficConcurrentWrites(t *testing.T) {
	BeginProxyTrafficSession()
	tracker := NewTCPTracker(trafficConn{proxy: true}, &Manager{}, &C.Metadata{}, nil, 0, 0, true)
	var workers sync.WaitGroup
	for i := 0; i < 8; i++ {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for n := 0; n < 1000; n++ {
				tracker.Write([]byte("123"))
				ReadProxyTraffic()
			}
		}()
	}
	workers.Wait()
	tracker.Close()
	if got := ReadProxyTraffic().Upload; got != 24000 {
		t.Fatalf("lost bytes: %d", got)
	}
}
