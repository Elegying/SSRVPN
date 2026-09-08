#include "physical_tcp_latency_probe.h"
#include <winsock2.h>
#include <ws2tcpip.h>
#include <cstdio>
#include <cstdlib>

void Require(bool value, const char* label) {
  if (!value) { std::fprintf(stderr, "FAIL: %s\n", label); std::exit(1); }
}

int main() {
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
  std::puts("Windows physical TCP latency tests passed.");
  return 0;
}
