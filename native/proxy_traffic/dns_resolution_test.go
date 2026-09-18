package dns

import (
	"context"
	"errors"
	"net"
	"testing"
	"time"

	D "github.com/miekg/dns"
)

type ssrvpnFamilyDNS struct {
	stalled uint16
	empty   bool
}

func (ssrvpnFamilyDNS) Address() string  { return "synthetic" }
func (ssrvpnFamilyDNS) ResetConnection() {}
func (c ssrvpnFamilyDNS) ExchangeContext(ctx context.Context, q *D.Msg) (*D.Msg, error) {
	kind := q.Question[0].Qtype
	if kind == c.stalled {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	m := new(D.Msg)
	m.SetReply(q)
	if c.empty {
		return m, nil
	}
	header := D.RR_Header{Name: q.Question[0].Name, Rrtype: kind, Class: D.ClassINET, Ttl: 60}
	if kind == D.TypeA {
		m.Answer = []D.RR{&D.A{Hdr: header, A: net.ParseIP("192.0.2.1")}}
	} else {
		m.Answer = []D.RR{&D.AAAA{Hdr: header, AAAA: net.ParseIP("2001:db8::1")}}
	}
	return m, nil
}

func TestSSRVPNAvailableDNSFamilyDoesNotWaitForStalledFamily(t *testing.T) {
	for _, stalled := range []uint16{D.TypeA, D.TypeAAAA} {
		r := NewResolverFromClient(ssrvpnFamilyDNS{stalled: stalled})
		r.ipv6Timeout = 10 * time.Millisecond
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		start := time.Now()
		ips, err := r.LookupIP(ctx, "family.synthetic.invalid")
		cancel()
		if err != nil || len(ips) != 1 || time.Since(start) > 500*time.Millisecond {
			t.Fatalf("stalled family blocked usable answer: kind=%d ips=%v err=%v", stalled, ips, err)
		}
		if ips[0].Is4() != (stalled == D.TypeAAAA) {
			t.Fatal(ips)
		}
	}
}

func TestSSRVPNDNSBothFamiliesAndCancellation(t *testing.T) {
	r := NewResolverFromClient(ssrvpnFamilyDNS{})
	ips, err := r.LookupIP(context.Background(), "both.synthetic.invalid")
	if err != nil || len(ips) != 2 || !ips[0].Is4() || !ips[1].Is6() {
		t.Fatalf("%v %v", ips, err)
	}
	r = NewResolverFromClient(ssrvpnFamilyDNS{empty: true})
	if ips, err = r.LookupIP(context.Background(), "empty.synthetic.invalid"); err == nil || len(ips) != 0 {
		t.Fatal("empty DNS accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = r.LookupIP(ctx, "cancel.synthetic.invalid")
	if !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}
