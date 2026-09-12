#ifndef SSRVPN_DNS_HTTP_RESPONSE_H_
#define SSRVPN_DNS_HTTP_RESPONSE_H_
#include <algorithm>
#include <cctype>
#include <string>
#include <vector>

namespace physical_tcp_latency {
// 0 = incomplete, 1 = complete, -1 = invalid. No redirects or compression.
inline int ParseDnsHttpResponse(const std::string& response,
                                std::vector<unsigned char>& body) {
  body.clear();
  if (response.size() > 80 * 1024) return -1;
  const auto end = response.find("\r\n\r\n");
  if (end == std::string::npos) return response.size() > 8192 ? -1 : 0;
  if (end > 8192 || (response.compare(0, 13, "HTTP/1.1 200 ") != 0 &&
                     response.compare(0, 13, "HTTP/1.0 200 ") != 0)) return -1;
  auto number = [](const std::string& text, unsigned base, size_t& out) {
    if (text.empty()) return false;
    out = 0;
    for (unsigned char c : text) {
      const unsigned digit = c >= '0' && c <= '9' ? c - '0' :
          c >= 'a' && c <= 'f' ? c - 'a' + 10 :
          c >= 'A' && c <= 'F' ? c - 'A' + 10 : 99;
      if (digit >= base || out > (65535 - digit) / base) return false;
      out = out * base + digit;
    }
    return true;
  };
  size_t length = 0;
  bool has_length = false, chunked = false, media = false;
  auto pos = response.find("\r\n") + 2;
  while (pos < end) {
    const auto next = response.find("\r\n", pos);
    const auto colon = response.find(':', pos);
    if (colon == std::string::npos || colon >= next) return -1;
    auto key = response.substr(pos, colon - pos);
    auto value = response.substr(colon + 1, next - colon - 1);
    auto lower = [](std::string& text) {
      std::transform(text.begin(), text.end(), text.begin(),
                     [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    };
    lower(key); lower(value);
    const auto begin = value.find_first_not_of(" \t");
    value = begin == std::string::npos ? "" :
        value.substr(begin, value.find_last_not_of(" \t") - begin + 1);
    if (key == "content-length") {
      if (has_length || !number(value, 10, length)) return -1;
      has_length = true;
    } else if (key == "transfer-encoding") {
      if (chunked || value != "chunked") return -1;
      chunked = true;
    } else if (key == "content-type") {
      if (media || value != "application/dns-message") return -1;
      media = true;
    } else if (key == "content-encoding" && value != "identity") return -1;
    pos = next + 2;
  }
  if (!media || (has_length == chunked)) return -1;
  pos = end + 4;
  if (has_length) {
    if (response.size() - pos < length) return 0;
    if (response.size() - pos != length) return -1;
    body.assign(response.begin() + pos, response.end());
    return 1;
  }
  while (true) {
    const auto next = response.find("\r\n", pos);
    if (next == std::string::npos) return 0;
    const auto line = response.substr(pos, next - pos);
    size_t chunk = 0;
    if (!number(line.substr(0, line.find(';')), 16, chunk)) return -1;
    pos = next + 2;
    if (!chunk) {
      if (response.size() < pos + 2) return 0;
      if (response.compare(pos, 2, "\r\n") == 0)
        return response.size() == pos + 2 ? 1 : -1;
      const auto trailer = response.find("\r\n\r\n", pos);
      if (trailer == std::string::npos) return 0;
      return response.size() == trailer + 4 ? 1 : -1;
    }
    if (body.size() + chunk > 65535) return -1;
    if (response.size() < pos + chunk + 2) return 0;
    if (response.compare(pos + chunk, 2, "\r\n") != 0) return -1;
    body.insert(body.end(), response.begin() + pos, response.begin() + pos + chunk);
    pos += chunk + 2;
  }
}
}
#endif
