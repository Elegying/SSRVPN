#include "physical_tcp_latency_probe.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <netioapi.h>
#include <windns.h>

#include <algorithm>
#include <cctype>
#include <limits>
#include <memory>
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

// The callback keeps this request alive after cancellation. No abandoned DNS
// task can start a TCP connection or retain a Flutter result/window pointer.
struct DnsRequest {
  std::wstring host;
  DNS_QUERY_REQUEST request{};
  DNS_QUERY_RESULT result{};
  DNS_QUERY_CANCEL cancel{};
  HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  ~DnsRequest() {
    if (result.pQueryRecords) DnsRecordListFree(result.pQueryRecords, DnsFreeRecordList);
    if (done) CloseHandle(done);
  }
};

void WINAPI DnsCompleted(void* opaque, DNS_QUERY_RESULT*) {
  std::unique_ptr<std::shared_ptr<DnsRequest>> owner(
      static_cast<std::shared_ptr<DnsRequest>*>(opaque));
  SetEvent((*owner)->done);
}

std::vector<IN_ADDR> Resolve(const std::string& host, ULONG index, DWORD timeout) {
  IN_ADDR numeric{};
  if (InetPtonA(AF_INET, host.c_str(), &numeric) == 1) return {numeric};
  auto state = std::make_shared<DnsRequest>();
  if (!state->done) return {};
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      host.data(), static_cast<int>(host.size()), nullptr, 0);
  if (count <= 0) return {};
  state->host.resize(count);
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, host.data(),
      static_cast<int>(host.size()), state->host.data(), count)) return {};
  state->request.Version = DNS_QUERY_REQUEST_VERSION1;
  state->request.QueryName = state->host.c_str();
  state->request.QueryType = DNS_TYPE_A;
  state->request.QueryOptions = DNS_QUERY_BYPASS_CACHE | DNS_QUERY_NO_HOSTS_FILE |
      DNS_QUERY_NO_MULTICAST | DNS_QUERY_TREAT_AS_FQDN;
  state->request.InterfaceIndex = index;
  state->request.pQueryCompletionCallback = DnsCompleted;
  auto* callback_owner = new std::shared_ptr<DnsRequest>(state);
  state->request.pQueryContext = callback_owner;
  state->result.Version = DNS_QUERY_RESULTS_VERSION1;
  const DNS_STATUS status = DnsQueryEx(&state->request, &state->result, &state->cancel);
  if (status == DNS_REQUEST_PENDING) {
    if (WaitForSingleObject(state->done, timeout) != WAIT_OBJECT_0) {
      DnsCancelQuery(&state->cancel);
      return {};
    }
  } else {
    delete callback_owner;
    if (status != ERROR_SUCCESS) return {};
  }
  if (state->result.QueryStatus != ERROR_SUCCESS) return {};
  std::vector<IN_ADDR> addresses;
  for (auto* record = state->result.pQueryRecords; record && addresses.size() < 32;
       record = record->pNext) {
    if (record->wType == DNS_TYPE_A && UsableIpv4(record->Data.A.IpAddress)) {
      IN_ADDR address{};
      address.s_addr = record->Data.A.IpAddress;
      addresses.push_back(address);
    }
  }
  return addresses;
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
  if (!network.index || !remaining()) return -1;
  for (const auto address : Resolve(host, network.index, remaining())) {
    if (!remaining() || !UsableIpv4(address.s_addr) || !IsPhysical(network.luid)) break;
    SOCKET socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socket == INVALID_SOCKET) continue;
    struct CloseSocket { SOCKET value; ~CloseSocket() { closesocket(value); } } close{socket};
    const DWORD interface_index = htonl(network.index);
    sockaddr_in local{};
    local.sin_family = AF_INET;
    local.sin_addr = network.source;
    // Bind interface AND source; never retry without either constraint.
    if (setsockopt(socket, IPPROTO_IP, IP_UNICAST_IF,
        reinterpret_cast<const char*>(&interface_index), sizeof(interface_index)) != 0 ||
        bind(socket, reinterpret_cast<sockaddr*>(&local), sizeof(local)) != 0) continue;
    u_long nonblocking = 1;
    if (ioctlsocket(socket, FIONBIO, &nonblocking) != 0) continue;
    sockaddr_in target{};
    target.sin_family = AF_INET;
    target.sin_port = htons(static_cast<u_short>(port));
    target.sin_addr = address;
    const int connected = connect(socket, reinterpret_cast<sockaddr*>(&target), sizeof(target));
    if (connected != 0 && WSAGetLastError() != WSAEWOULDBLOCK) continue;
    fd_set writable, failed;
    FD_ZERO(&writable); FD_ZERO(&failed);
    FD_SET(socket, &writable); FD_SET(socket, &failed);
    const DWORD wait = remaining();
    timeval deadline{static_cast<long>(wait / 1000), static_cast<long>((wait % 1000) * 1000)};
    if (!wait || select(0, nullptr, &writable, &failed, &deadline) <= 0 ||
        FD_ISSET(socket, &failed)) continue;
    int error = 0;
    int size = sizeof(error);
    if (getsockopt(socket, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&error), &size) != 0 ||
        error || !remaining() || !IsPhysical(network.luid)) continue;
    return std::max(1, static_cast<int>(GetTickCount64() - start));
  }
  return -1;
}
}  // namespace physical_tcp_latency
