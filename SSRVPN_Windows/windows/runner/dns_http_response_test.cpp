#include "dns_http_response.h"
#include "dns_question.h"
#include <cassert>
#include <iostream>

int main() {
  using physical_tcp_latency::ParseDnsHttpResponse;
  const auto question = physical_tcp_latency::BuildDnsQuestion("example.com.");
  assert(question.size() == 29 && question[5] == 1 && question[12] == 7);
  for (const auto& host : {std::string(""), std::string("bad..host"), std::string("bad/host"),
                           std::string(64, 'a') + ".com"})
    assert(physical_tcp_latency::BuildDnsQuestion(host).empty());
  std::vector<unsigned char> body;
  const std::string header = "HTTP/1.1 200 OK\r\nContent-Type: application/dns-message\r\n";
  const auto fixed = header + "Content-Length: 3\r\n\r\nabc";
  const auto chunks = header + "Transfer-Encoding: chunked\r\n\r\n1\r\na\r\n2\r\nbc\r\n0\r\n\r\n";
  for (const auto& reply : {fixed, chunks}) {
    for (size_t i = 0; i < reply.size(); ++i)
      assert(ParseDnsHttpResponse(reply.substr(0, i), body) == 0);
    assert(ParseDnsHttpResponse(reply, body) == 1);
    assert(std::string(body.begin(), body.end()) == "abc");
  }
  for (const auto& reply : {
       header + "Content-Length: 3\r\nContent-Length: 3\r\n\r\nabc",
       header + "Content-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\nabc",
       header + "Content-Length: 65536\r\n\r\n",
       header + "Transfer-Encoding: chunked\r\n\r\nFFFFFFFFFFFFFFFF\r\n",
       header + "Content-Length: 3\r\nContent-Encoding: gzip\r\n\r\nabc",
       std::string("HTTP/1.1 302 Found\r\nContent-Length: 0\r\n\r\n"),
       fixed + "unexpected"})
    assert(ParseDnsHttpResponse(reply, body) == -1);
  std::cout << "DNS HTTP framing: fragmented, chunked, bounded and fail-closed passed.\n";
}
