#ifndef SSRVPN_PHYSICAL_DNS_H_
#define SSRVPN_PHYSICAL_DNS_H_
#include <winsock2.h>
#include <functional>
#include <string>
#include <vector>

namespace physical_tcp_latency {
// The caller owns and has already bound this nonblocking socket to a physical
// interface. TLS authenticates dns.alidns.com; no system resolver/proxy is used.
std::vector<IN_ADDR> QueryPhysicalDns(SOCKET socket, const std::string& host,
                                     const std::function<DWORD()>& remaining, DWORD& ttl);
}
#endif
