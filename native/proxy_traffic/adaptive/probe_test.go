package adaptive

import (
	"context"
	"errors"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

type probePacket struct {
	answer      []byte
	target      net.Addr
	wrongSource bool
	closed      int32
}

func (p *probePacket) WriteTo(b []byte, a net.Addr) (int, error) {
	p.target = a
	p.answer = append([]byte(nil), b...)
	p.answer[2] |= 0x80
	p.answer[7] = 1
	return len(b), nil
}
func (p *probePacket) ReadFrom(b []byte) (int, net.Addr, error) {
	a := p.target
	if p.wrongSource {
		a = &net.UDPAddr{IP: net.IPv4(192, 0, 2, 1), Port: 53}
	}
	return copy(b, p.answer), a, nil
}
func (p *probePacket) Close() error        { atomic.StoreInt32(&p.closed, 1); return nil }
func (p *probePacket) LocalAddr() net.Addr { return &net.UDPAddr{} }
func (p *probePacket) SetDeadline(time.Time) error {
	return errors.New("combined deadline unsupported")
}
func (p *probePacket) SetReadDeadline(time.Time) error  { return nil }
func (p *probePacket) SetWriteDeadline(time.Time) error { return nil }

func TestAdaptiveUDPRequiresResponseFromRequestedExit(t *testing.T) {
	for _, wrong := range []bool{false, true} {
		p := &probePacket{wrongSource: wrong}
		got := probeUDP(context.Background(), func(context.Context) (net.PacketConn, error) { return p, nil }, "2606:4700:4700::1111")
		if got == wrong {
			t.Fatalf("wrong source=%v accepted=%v", wrong, got)
		}
		if atomic.LoadInt32(&p.closed) == 0 {
			t.Fatal("probe leaked packet connection")
		}
	}
}
func TestAdaptiveProbeFailuresRemainUnknown(t *testing.T) {
	s := Probe(context.Background(), func(context.Context, string) (net.Conn, error) { return nil, errors.New("offline") }, func(context.Context) (net.PacketConn, error) { return nil, errors.New("offline") })
	if s.IPv4 || s.IPv6 {
		t.Fatal(s)
	}
}
