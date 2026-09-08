#ifndef SSRVPN_PHYSICAL_TCP_LATENCY_PROBE_H_
#define SSRVPN_PHYSICAL_TCP_LATENCY_PROBE_H_

#include <cstdint>
#include <string>

namespace physical_tcp_latency {
bool ValidArguments(const std::string& host, int port, int timeout_ms);
bool UsableIpv4(uint32_t network_order_address);
int Probe(const std::string& host, int port, int timeout_ms);
}  // namespace physical_tcp_latency

#endif
