#include "physical_tcp_latency_probe.h"
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
  if (argc == 2 && std::strcmp(argv[1], "--live") == 0) {
    // Dynamic WFP session: replicate strict-route's DNS block; it is removed
    // even if this test crashes. No routes, adapters or persistent rules change.
    HANDLE engine = nullptr;
    FWPM_SESSION0 session{};
    session.flags = FWPM_SESSION_FLAG_DYNAMIC;
    Require(FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr, &session, &engine) == ERROR_SUCCESS,
            "open dynamic DNS-block test session");
    FWPM_FILTER_CONDITION0 condition{};
    condition.fieldKey = FWPM_CONDITION_IP_REMOTE_PORT;
    condition.matchType = FWP_MATCH_EQUAL;
    condition.conditionValue.type = FWP_UINT16;
    condition.conditionValue.uint16 = 53;
    FWPM_FILTER0 filter{};
    filter.displayData.name = const_cast<wchar_t*>(L"SSRVPN transient latency regression test");
    filter.layerKey = FWPM_LAYER_ALE_AUTH_CONNECT_V4;
    filter.subLayerKey = FWPM_SUBLAYER_UNIVERSAL;
    filter.action.type = FWP_ACTION_BLOCK;
    filter.numFilterConditions = 1;
    filter.filterCondition = &condition;
    UINT64 id = 0;
    Require(FwpmFilterAdd0(engine, &filter, nullptr, &id) == ERROR_SUCCESS,
            "install transient port-53 block");
    const int numeric = Probe("223.5.5.5", 443, 5000);
    const int domain = Probe("dns.alidns.com", 443, 5000);
    FwpmEngineClose0(engine);
    std::printf("Port-53 blocked: physical IPv4=%d, physical encrypted DNS+TCP=%d ms\n", numeric, domain);
    Require(numeric > 0, "live physical IPv4 probe succeeds");
    Require(domain > 0, "live domain probe succeeds while DNS port 53 is blocked");
  }
  std::puts("Windows physical TCP latency tests passed.");
  return 0;
}
