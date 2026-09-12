#ifndef SSRVPN_DNS_QUESTION_H_
#define SSRVPN_DNS_QUESTION_H_
#include <string>
#include <vector>

namespace physical_tcp_latency {
// One RFC 1035 IN/A question; DoH uses transaction ID zero (RFC 8484).
inline std::vector<unsigned char> BuildDnsQuestion(std::string host) {
  if (!host.empty() && host.back() == '.') host.pop_back();
  if (host.empty() || host.size() > 253) return {};
  std::vector<unsigned char> bytes{0,0,1,0,0,1,0,0,0,0,0,0};
  for (size_t start = 0; start < host.size();) {
    auto end = host.find('.', start);
    if (end == std::string::npos) end = host.size();
    const auto size = end - start;
    if (!size || size > 63) return {};
    bytes.push_back(static_cast<unsigned char>(size));
    for (size_t i = start; i < end; ++i) {
      const unsigned char c = host[i];
      if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '-' || c == '_')) return {};
      bytes.push_back(c);
    }
    start = end + 1;
  }
  bytes.insert(bytes.end(), {0,0,1,0,1});
  return bytes;
}
}
#endif
