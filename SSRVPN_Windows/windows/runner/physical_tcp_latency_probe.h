#ifndef SSRVPN_PHYSICAL_TCP_LATENCY_PROBE_H_
#define SSRVPN_PHYSICAL_TCP_LATENCY_PROBE_H_

#include <cstdint>
#include <string>

namespace physical_tcp_latency {
// Shared wire codes, mirrored by PhysicalTcpLatencyFailure in Dart.
constexpr int kTimedOut = -10;
constexpr int kDnsFailed = -11;
constexpr int kNoNetwork = -12;
constexpr int kConnectFailed = -13;
constexpr int kBusy = -14;
bool ValidArguments(const std::string& host, int port, int timeout_ms);
bool UsableIpv4(uint32_t network_order_address);
int Probe(const std::string& host, int port, int timeout_ms);
}  // namespace physical_tcp_latency

#endif
