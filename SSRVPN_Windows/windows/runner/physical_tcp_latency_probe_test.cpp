#include "physical_tcp_latency_probe.h"
#include "physical_dns.h"
#include "dns_question.h"
#include <windns.h>
#include <array>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <cstdio>
#include <cstdlib>
#include <windows.h>
#include <fwpmu.h>
#include <cstring>

void Require(bool value, const char* label) {
  if (!value) { std::fprintf(stderr, "FAIL: %s\n", label); std::exit(1); }
}

int main(int argc, char** argv) {
  using namespace physical_tcp_latency;
  for (const char* text : {"198.18.0.1", "198.19.255.254", "127.0.0.1",
                          "0.0.0.0", "169.254.1.2", "224.0.0.1"}) {
    IN_ADDR address{};
    Require(InetPtonA(AF_INET, text, &address) == 1, text);
    Require(!UsableIpv4(address.s_addr), text);
  }
  for (const char* text : {"1.1.1.1", "192.168.1.1", "198.20.0.1"}) {
    IN_ADDR address{};
    Require(InetPtonA(AF_INET, text, &address) == 1, text);
    Require(UsableIpv4(address.s_addr), text);
  }
  Require(ValidArguments("relay.example", 443, 5000), "valid request");
  Require(!ValidArguments("bad host", 443, 5000), "invalid hostname");
  Require(!ValidArguments("relay.example", 65536, 5000), "invalid port");
  Require(!ValidArguments("relay.example", 443, 0), "invalid deadline");
  Require(Probe("127.0.0.1", 443, 50) == -1, "never measure loopback stack");
  Require(Probe("198.18.0.1", 443, 50) == -1, "never measure fake-IP stack");
  const auto query = BuildDnsQuestion("example.com");
  const auto bytes = query.size();
  Require(bytes == 29, "build DNS wire question");
  Require(query[4] == 0 && query[5] == 1, "query counts use network byte order");
  std::vector<unsigned char> reply(query.begin(), query.begin() + bytes);
  reply[2] = 0x81; reply[3] = 0x80; reply[7] = 1;
  const unsigned char answer[] = {0xc0,0x0c,0,1,0,1,0,0,0,30,0,4,1,1,1,1};
  reply.insert(reply.end(), std::begin(answer), std::end(answer));
  DWORD ttl = 0;
  Require(ParsePhysicalDns(reply, ttl).size() == 1 && ttl == 30,
          "parse wire DNS with host-order header conversion and TTL");
  reply[reply.size()-4] = 198; reply[reply.size()-3] = 18;
  Require(ParsePhysicalDns(reply, ttl).empty(), "reject fake-IP in encrypted DNS answer");
  reply[2] |= 2;
  Require(ParsePhysicalDns(reply, ttl).empty(), "reject truncated DNS response");
  if (argc == 2 && std::strcmp(argv[1], "--live") == 0) {
    // Dynamic WFP session: replicate strict-route's DNS block; it is removed
    // even if this test crashes. No routes, adapters or persistent rules change.
    HANDLE engine = nullptr;
    FWPM_SESSION0 session{};
    session.flags = FWPM_SESSION_FLAG_DYNAMIC;
    Require(FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr, &session, &engine) == ERROR_SUCCESS,
            "open dynamic DNS-block test session");
    GUID layer_id{0x8d794d2a, 0xa31b, 0x4c3e, {0x9a,0x11,0x63,0x42,0x22,0x55,0x14,0x91}};
    layer_id.Data1 ^= GetCurrentProcessId();
    FWPM_SUBLAYER0 layer{};
    layer.subLayerKey = layer_id;
    layer.displayData.name = const_cast<wchar_t*>(L"SSRVPN transient regression layer");
    layer.weight = 65535;
    Require(FwpmSubLayerAdd0(engine, &layer, nullptr) == ERROR_SUCCESS, "add strict-route priority sublayer");
    FWPM_FILTER_CONDITION0 condition{};
    condition.fieldKey = FWPM_CONDITION_IP_REMOTE_PORT;
    condition.matchType = FWP_MATCH_EQUAL;
    condition.conditionValue.type = FWP_UINT16;
    condition.conditionValue.uint16 = 53;
    FWPM_FILTER0 filter{};
    filter.displayData.name = const_cast<wchar_t*>(L"SSRVPN transient latency regression test");
    filter.layerKey = FWPM_LAYER_ALE_AUTH_CONNECT_V4;
    filter.subLayerKey = layer_id;
    filter.weight.type = FWP_UINT8;
    filter.weight.uint8 = 10;
    filter.action.type = FWP_ACTION_BLOCK;
    filter.numFilterConditions = 1;
    filter.filterCondition = &condition;
    UINT64 id = 0;
    Require(FwpmFilterAdd0(engine, &filter, nullptr, &id) == ERROR_SUCCESS,
            "install transient port-53 block");
    WSADATA data{};
    Require(WSAStartup(MAKEWORD(2, 2), &data) == 0, "start blocked-DNS control");
    const SOCKET control = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    u_long nonblocking = 1;
    Require(ioctlsocket(control, FIONBIO, &nonblocking) == 0, "nonblocking DNS control");
    sockaddr_in dns{};
    dns.sin_family = AF_INET; dns.sin_port = htons(53);
    InetPtonA(AF_INET, "223.5.5.5", &dns.sin_addr);
    const int connected = connect(control, reinterpret_cast<sockaddr*>(&dns), sizeof(dns));
    int blocked_error = connected == 0 ? 0 : WSAGetLastError();
    if (blocked_error == WSAEWOULDBLOCK) {
      fd_set write, errors;
      FD_ZERO(&write); FD_ZERO(&errors); FD_SET(control, &write); FD_SET(control, &errors);
      timeval wait{1, 0};
      if (select(0, nullptr, &write, &errors, &wait) > 0) {
        int size = sizeof(blocked_error);
        getsockopt(control, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&blocked_error), &size);
      }
    }
    closesocket(control);
    WSACleanup();
    const int numeric = Probe("223.5.5.5", 443, 5000);
    const int domain = Probe("dns.alidns.com", 443, 5000);
    FwpmEngineClose0(engine);
    std::printf("Port-53 blocked: physical IPv4=%d, physical encrypted DNS+TCP=%d ms\n", numeric, domain);
    std::printf("Blocked ordinary DNS control Winsock error=%d\n", blocked_error);
    Require(blocked_error == WSAEACCES, "control proves DNS is blocked by WFP");
    Require(numeric > 0, "live physical IPv4 probe succeeds");
    Require(domain > 0, "live domain probe succeeds while DNS port 53 is blocked");
  }
  std::puts("Windows physical TCP latency tests passed.");
  return 0;
}
