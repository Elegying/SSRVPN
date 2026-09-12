#include "physical_tcp_latency_probe.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include "physical_dns.h"

#include <algorithm>
#include <cctype>
#include <limits>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace physical_tcp_latency {
namespace {
struct Network {
  NET_LUID luid{};
  ULONG index = 0;
  IN_ADDR source{};
};

bool IsPhysical(NET_LUID luid) {
  MIB_IF_ROW2 row{};
  row.InterfaceLuid = luid;
  return GetIfEntry2(&row) == NO_ERROR && row.OperStatus == IfOperStatusUp &&
         row.InterfaceAndOperStatusFlags.HardwareInterface &&
         !row.InterfaceAndOperStatusFlags.FilterInterface &&
         (row.Type == IF_TYPE_ETHERNET_CSMACD || row.Type == IF_TYPE_IEEE80211);
}

Network ChooseNetwork() {
  ULONG size = 16 * 1024;
  std::vector<unsigned char> storage(size);
  ULONG status = ERROR_BUFFER_OVERFLOW;
  for (int attempt = 0; attempt < 3 && status == ERROR_BUFFER_OVERFLOW; ++attempt) {
    if (size > 1024 * 1024) return {};
    storage.resize(size);
    status = GetAdaptersAddresses(AF_INET, GAA_FLAG_INCLUDE_GATEWAYS, nullptr,
        reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data()), &size);
  }
  if (status != NO_ERROR) return {};
  Network selected;
  ULONG best_metric = std::numeric_limits<ULONG>::max();
  for (auto* adapter = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(storage.data());
       adapter; adapter = adapter->Next) {
    if (!adapter->IfIndex || !adapter->FirstGatewayAddress ||
        !IsPhysical(adapter->Luid) || adapter->Ipv4Metric >= best_metric) continue;
    for (auto* address = adapter->FirstUnicastAddress; address; address = address->Next) {
      if (address->Address.lpSockaddr->sa_family != AF_INET ||
          address->DadState != IpDadStatePreferred) continue;
      auto source = reinterpret_cast<sockaddr_in*>(address->Address.lpSockaddr)->sin_addr;
      if (!UsableIpv4(source.s_addr)) continue;
      selected = {adapter->Luid, adapter->IfIndex, source};
      best_metric = adapter->Ipv4Metric;
      break;
    }
  }
  return selected;
}

SOCKET Connect(const Network& network, IN_ADDR address, int port, DWORD timeout) {
  SOCKET socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (socket == INVALID_SOCKET) return INVALID_SOCKET;
  const DWORD index = htonl(network.index);
  sockaddr_in local{};
  local.sin_family = AF_INET;
  local.sin_addr = network.source;
  u_long nonblocking = 1;
  if (setsockopt(socket, IPPROTO_IP, IP_UNICAST_IF,
      reinterpret_cast<const char*>(&index), sizeof(index)) != 0 ||
      bind(socket, reinterpret_cast<sockaddr*>(&local), sizeof(local)) != 0 ||
      ioctlsocket(socket, FIONBIO, &nonblocking) != 0) {
    closesocket(socket);
    return INVALID_SOCKET;
  }
  sockaddr_in target{};
  target.sin_family = AF_INET;
  target.sin_addr = address;
  target.sin_port = htons(static_cast<u_short>(port));
  const int status = connect(socket, reinterpret_cast<sockaddr*>(&target), sizeof(target));
  if (status != 0 && WSAGetLastError() != WSAEWOULDBLOCK) {
    closesocket(socket);
    return INVALID_SOCKET;
  }
  fd_set writable, failed;
  FD_ZERO(&writable); FD_ZERO(&failed);
  FD_SET(socket, &writable); FD_SET(socket, &failed);
  timeval deadline{static_cast<long>(timeout / 1000), static_cast<long>((timeout % 1000) * 1000)};
  int error = 0;
  int size = sizeof(error);
  if (!timeout || select(0, nullptr, &writable, &failed, &deadline) <= 0 ||
      FD_ISSET(socket, &failed) ||
      getsockopt(socket, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&error), &size) != 0 ||
      error || !IsPhysical(network.luid)) {
    closesocket(socket);
    return INVALID_SOCKET;
  }
  return socket;
}

std::vector<IN_ADDR> Resolve(const std::string& host, const Network& network,
                           const std::function<DWORD()>& remaining) {
  IN_ADDR numeric{};
  if (InetPtonA(AF_INET, host.c_str(), &numeric) == 1) return {numeric};
  struct Cached { std::vector<IN_ADDR> addresses; ULONGLONG expires; };
  static std::mutex cache_mutex;
  static std::unordered_map<std::string, Cached> cache;
  const auto key = std::to_string(network.luid.Value) + ":" +
      std::to_string(network.source.s_addr) + ":" + host;
  {
    std::lock_guard<std::mutex> lock(cache_mutex);
    const auto found = cache.find(key);
    if (found != cache.end() && found->second.expires > GetTickCount64())
      return found->second.addresses;
  }
  // Numeric bootstrap avoids both TUN fake-IP and the strict-route port-53
  // firewall. Each attempt has a bounded share of the ORIGINAL total deadline.
  const char* resolvers[] = {"223.5.5.5", "223.6.6.6"};
  for (size_t i = 0; i < 2; ++i) {
    const char* resolver = resolvers[i];
    const DWORD budget = remaining();
    if (!budget) break;
    const ULONGLONG end = GetTickCount64() + (i == 0 ? budget / 2 : budget);
    const std::function<DWORD()> attempt = [&]() -> DWORD {
      const auto now = GetTickCount64();
      return now < end ? std::min(remaining(), static_cast<DWORD>(end - now)) : 0;
    };
    IN_ADDR address{};
    InetPtonA(AF_INET, resolver, &address);
    const SOCKET socket = Connect(network, address, 443, attempt());
    if (socket == INVALID_SOCKET) continue;
    struct Close { SOCKET value; ~Close() { closesocket(value); } } close{socket};
    DWORD ttl = 0;
    auto addresses = QueryPhysicalDns(socket, host, attempt, ttl);
    if (!addresses.empty() && IsPhysical(network.luid)) {
      if (ttl && remaining()) {
        std::lock_guard<std::mutex> lock(cache_mutex);
        if (cache.size() >= 128) cache.erase(cache.begin());
        cache[key] = {addresses, GetTickCount64() + static_cast<ULONGLONG>(ttl) * 1000};
      }
      return addresses;
    }
  }
  return {};
}
}  // namespace

bool ValidArguments(const std::string& host, int port, int timeout_ms) {
  return !host.empty() && host.size() <= 253 && port > 0 && port <= 65535 &&
      timeout_ms > 0 && timeout_ms <= 60000 &&
      std::none_of(host.begin(), host.end(), [](unsigned char c) {
        return c == 0 || std::isspace(c);
      });
}

bool UsableIpv4(uint32_t address) {
  const uint32_t host = ntohl(address);
  const uint32_t first = host >> 24;
  return first != 0 && first != 127 && first < 224 &&
      (host >> 16) != 0xa9fe && (host >> 17) != (0xc6120000u >> 17);
}

int Probe(const std::string& host, int port, int timeout_ms) {
  if (!ValidArguments(host, port, timeout_ms)) return -1;
  IN_ADDR numeric{};
  if (InetPtonA(AF_INET, host.c_str(), &numeric) == 1 && !UsableIpv4(numeric.s_addr)) return -1;
  const ULONGLONG start = GetTickCount64();
  auto remaining = [&]() -> DWORD {
    const ULONGLONG elapsed = GetTickCount64() - start;
    return elapsed < static_cast<ULONGLONG>(timeout_ms)
        ? static_cast<DWORD>(timeout_ms - elapsed) : 0;
  };
  WSADATA data{};
  if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return -1;
  struct Cleanup { ~Cleanup() { WSACleanup(); } } cleanup;
  const auto network = ChooseNetwork();
  if (!network.index) return kNoNetwork;
  if (!remaining()) return kTimedOut;
  const auto addresses = Resolve(host, network, remaining);
  if (addresses.empty()) return kDnsFailed;
  for (size_t i = 0; i < addresses.size(); ++i) {
    if (!remaining()) return kTimedOut;
    if (!IsPhysical(network.luid)) return kNoNetwork;
    if (!UsableIpv4(addresses[i].s_addr)) continue;
    // An unreachable first A record must not consume the entire multi-IP probe.
    const DWORD budget = std::max<DWORD>(1, remaining() / static_cast<DWORD>(addresses.size() - i));
    const SOCKET socket = Connect(network, addresses[i], port, budget);
    if (socket == INVALID_SOCKET) continue;
    closesocket(socket);
    if (!remaining()) return kTimedOut;
    return std::max(1, static_cast<int>(GetTickCount64() - start));
  }
  return remaining() ? kConnectFailed : kTimedOut;
}
}  // namespace physical_tcp_latency
