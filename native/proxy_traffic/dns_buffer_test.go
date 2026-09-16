// Copy into component/resolver of the exact audited upstream source checkout.
// This calls its real RelayDnsPacket, with a synthetic DNS service only.
package resolver

import (
	"bytes"
	"context"
	"net"
	"testing"

	D "github.com/miekg/dns"
)

type ssrvpnDNSService struct{}

func (ssrvpnDNSService) ServeMsg(_ context.Context, q *D.Msg) (*D.Msg, error) {
	r := new(D.Msg)
	r.SetReply(q)
	for i := 0; i < 120; i++ {
		r.Answer = append(r.Answer, &D.A{
			Hdr: D.RR_Header{Name: q.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 60},
			A:   net.IPv4(192, 0, 2, byte(i+1)),
		})
	}
	return r, nil
}

func TestSSRVPNDNSPackedBytesRemainInCallerBuffer(t *testing.T) {
	previous := DefaultService
	DefaultService = ssrvpnDNSService{}
	t.Cleanup(func() { DefaultService = previous })
	q := new(D.Msg)
	q.SetQuestion("many-records.synthetic-audit.invalid.", D.TypeA)
	q.Id = 0x1357
	payload, err := q.Pack()
	if err != nil {
		t.Fatal(err)
	}
	target := bytes.Repeat([]byte{0xa5}, SafeDnsPacketSize)
	packed, err := RelayDnsPacket(context.Background(), payload, target)
	if err != nil {
		t.Fatal(err)
	}
	decoded := new(D.Msg)
	if err := decoded.Unpack(packed); err != nil {
		t.Fatal(err)
	}
	if decoded.Id != q.Id || len(decoded.Answer) != 120 {
		t.Fatalf("invalid fixture: %#v", decoded.MsgHdr)
	}
	if len(packed) > len(target) {
		t.Fatalf("fixture does not fit: %d", len(packed))
	}
	if !bytes.Equal(target[:len(packed)], packed) {
		t.Fatalf("real RelayDnsPacket returned %d valid bytes in a different buffer; TUN caller would send stale bytes, first=%x expected=%x", len(packed), target[:2], packed[:2])
	}
}
