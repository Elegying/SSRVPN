#include "physical_dns.h"
#include "dns_http_response.h"
#include <ws2tcpip.h>
#include <windows.h>
#define SECURITY_WIN32
#include <security.h>
#include <schannel.h>
#include <windns.h>
#include <algorithm>
#include <array>
#include <cstring>
#include <memory>
#include "physical_tcp_latency_probe.h"

namespace physical_tcp_latency {
namespace {
// Bounded TLS/HTTP exchange on the SAME socket that the caller bound. WinHTTP
// cannot guarantee that binding on all supported Windows versions.
class TlsExchange {
 public:
  TlsExchange(SOCKET socket, const std::function<DWORD()>& remaining)
      : socket_(socket), remaining_(remaining) {
    SecInvalidateHandle(&credential_);
    SecInvalidateHandle(&context_);
  }
  ~TlsExchange() {
    if (SecIsValidHandle(&context_)) DeleteSecurityContext(&context_);
    if (SecIsValidHandle(&credential_)) FreeCredentialsHandle(&credential_);
  }
  bool Handshake() {
    SCHANNEL_CRED options{};
    options.dwVersion = SCHANNEL_CRED_VERSION;
    options.grbitEnabledProtocols = SP_PROT_TLS1_2_CLIENT;
    options.dwFlags = SCH_CRED_AUTO_CRED_VALIDATION | SCH_CRED_NO_DEFAULT_CREDS |
                      SCH_USE_STRONG_CRYPTO;
    TimeStamp expiry{};
    if (AcquireCredentialsHandleW(nullptr, const_cast<wchar_t*>(UNISP_NAME_W),
        SECPKG_CRED_OUTBOUND, nullptr, &options, nullptr, nullptr, &credential_,
        &expiry) != SEC_E_OK) return false;
    bool first = true;
    while (remaining_()) {
      SecBuffer input[2] = {{static_cast<ULONG>(encrypted_.size()), SECBUFFER_TOKEN,
                            encrypted_.data()}, {0, SECBUFFER_EMPTY, nullptr}};
      SecBufferDesc inputs{SECBUFFER_VERSION, 2, input};
      SecBuffer output{0, SECBUFFER_TOKEN, nullptr};
      SecBufferDesc outputs{SECBUFFER_VERSION, 1, &output};
      ULONG attributes = 0;
      const auto status = InitializeSecurityContextW(&credential_,
          first ? nullptr : &context_, const_cast<wchar_t*>(L"dns.alidns.com"),
          ISC_REQ_STREAM | ISC_REQ_CONFIDENTIALITY | ISC_REQ_REPLAY_DETECT |
          ISC_REQ_SEQUENCE_DETECT | ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_EXTENDED_ERROR,
          0, SECURITY_NATIVE_DREP, first ? nullptr : &inputs, 0, &context_,
          &outputs, &attributes, &expiry);
      first = false;
      bool sent = true;
      if (output.pvBuffer) {
        if (status == SEC_E_OK || status == SEC_I_CONTINUE_NEEDED)
          sent = Send(static_cast<const char*>(output.pvBuffer), output.cbBuffer);
        FreeContextBuffer(output.pvBuffer);
      }
      if (!sent) return false;
      if (status == SEC_E_INCOMPLETE_MESSAGE) {
        if (!Receive()) return false;
        continue;
      }
      if (status != SEC_E_OK && status != SEC_I_CONTINUE_NEEDED) return false;
      KeepExtra(input[1]);
      if (status == SEC_E_OK)
        return QueryContextAttributesW(&context_, SECPKG_ATTR_STREAM_SIZES,
                                        &sizes_) == SEC_E_OK;
      if (encrypted_.empty() && !Receive()) return false;
    }
    return false;
  }
  bool Write(const std::string& text) {
    if (text.size() > sizes_.cbMaximumMessage) return false;
    std::vector<char> bytes(sizes_.cbHeader + text.size() + sizes_.cbTrailer);
    std::memcpy(bytes.data() + sizes_.cbHeader, text.data(), text.size());
    SecBuffer buffers[4] = {
      {sizes_.cbHeader, SECBUFFER_STREAM_HEADER, bytes.data()},
      {static_cast<ULONG>(text.size()), SECBUFFER_DATA, bytes.data() + sizes_.cbHeader},
      {sizes_.cbTrailer, SECBUFFER_STREAM_TRAILER, bytes.data() + sizes_.cbHeader + text.size()},
      {0, SECBUFFER_EMPTY, nullptr}};
    SecBufferDesc message{SECBUFFER_VERSION, 4, buffers};
    if (EncryptMessage(&context_, 0, &message, 0) != SEC_E_OK) return false;
    return Send(bytes.data(), buffers[0].cbBuffer + buffers[1].cbBuffer + buffers[2].cbBuffer);
  }
  bool Read(std::string& plain) {
    while (remaining_()) {
      if (encrypted_.empty() && !Receive()) return false;
      SecBuffer buffers[4] = {
        {static_cast<ULONG>(encrypted_.size()), SECBUFFER_DATA, encrypted_.data()},
        {0, SECBUFFER_EMPTY, nullptr}, {0, SECBUFFER_EMPTY, nullptr},
        {0, SECBUFFER_EMPTY, nullptr}};
      SecBufferDesc message{SECBUFFER_VERSION, 4, buffers};
      const auto status = DecryptMessage(&context_, &message, 0, nullptr);
      if (status == SEC_E_INCOMPLETE_MESSAGE) {
        if (!Receive()) return false;
        continue;
      }
      // No renegotiation, insecure downgrade, or unauthenticated partial reply.
      if (status != SEC_E_OK) return false;
      SecBuffer extra{0, SECBUFFER_EMPTY, nullptr};
      for (const auto& buffer : buffers) {
        if (buffer.BufferType == SECBUFFER_DATA) {
          if (plain.size() + buffer.cbBuffer > 80 * 1024) return false;
          plain.append(static_cast<const char*>(buffer.pvBuffer), buffer.cbBuffer);
        } else if (buffer.BufferType == SECBUFFER_EXTRA) extra = buffer;
      }
      KeepExtra(extra);
      return true;
    }
    return false;
  }
 private:
  bool Wait(bool writing) {
    const DWORD ms = remaining_();
    if (!ms) return false;
    fd_set ready;
    FD_ZERO(&ready); FD_SET(socket_, &ready);
    timeval timeout{static_cast<long>(ms / 1000), static_cast<long>((ms % 1000) * 1000)};
    return select(0, writing ? nullptr : &ready, writing ? &ready : nullptr,
                  nullptr, &timeout) > 0;
  }
  bool Send(const char* bytes, size_t size) {
    while (size && remaining_()) {
      const int written = send(socket_, bytes, static_cast<int>(size), 0);
      if (written > 0) { bytes += written; size -= written; }
      else if (written < 0 && WSAGetLastError() == WSAEWOULDBLOCK) {
        if (!Wait(true)) return false;
      } else return false;
    }
    return size == 0;
  }
  bool Receive() {
    if (encrypted_.size() >= 64 * 1024) return false;
    std::array<char, 16 * 1024> buffer{};
    while (remaining_()) {
      const int count = recv(socket_, buffer.data(), static_cast<int>(buffer.size()), 0);
      if (count > 0) {
        encrypted_.insert(encrypted_.end(), buffer.data(), buffer.data() + count);
        return true;
      }
      if (count == 0 || WSAGetLastError() != WSAEWOULDBLOCK || !Wait(false)) return false;
    }
    return false;
  }
  void KeepExtra(const SecBuffer& extra) {
    const size_t size = extra.BufferType == SECBUFFER_EXTRA ? extra.cbBuffer : 0;
    if (size && size <= encrypted_.size())
      encrypted_.erase(encrypted_.begin(), encrypted_.end() - size);
    else encrypted_.clear();
  }
  SOCKET socket_;
  const std::function<DWORD()>& remaining_;
  CredHandle credential_{};
  CtxtHandle context_{};
  SecPkgContext_StreamSizes sizes_{};
  std::vector<char> encrypted_;
};
}  // namespace

std::vector<IN_ADDR> QueryPhysicalDns(SOCKET socket, const std::string& host,
                                     const std::function<DWORD()>& remaining, DWORD& ttl) {
  ttl = 60;
  // Windows' DNS codec creates/parses wire messages; TLS uses the system trust
  // store and verifies the resolver hostname. Never call DnsQueryEx here.
  std::array<unsigned char, 512> query{};
  DWORD query_size = static_cast<DWORD>(query.size());
  if (!DnsWriteQuestionToBuffer_UTF8(reinterpret_cast<PDNS_MESSAGE_BUFFER>(query.data()),
      &query_size, host.c_str(), DNS_TYPE_A, 0, TRUE)) return {};
  TlsExchange tls(socket, remaining);
  if (!tls.Handshake()) return {};
  const std::string request = "POST /dns-query HTTP/1.1\r\nHost: dns.alidns.com\r\n"
      "Content-Type: application/dns-message\r\nAccept: application/dns-message\r\n"
      "Connection: close\r\nContent-Length: " + std::to_string(query_size) + "\r\n\r\n" +
      std::string(reinterpret_cast<const char*>(query.data()), query_size);
  if (!tls.Write(request)) return {};
  std::string response;
  std::vector<unsigned char> body;
  while (remaining()) {
    if (!tls.Read(response)) return {};
    const int state = ParseDnsHttpResponse(response, body);
    if (state < 0) return {};
    if (state > 0) break;
  }
  if (body.size() < 12 || body.size() > 65535 || body[0] != 0 || body[1] != 0 ||
      (body[2] & 0xFA) != 0x80 || (body[3] & 0x0F) != 0) return {};
  PDNS_RECORD records = nullptr;
  DNS_BYTE_FLIP_HEADER_COUNTS(&reinterpret_cast<PDNS_MESSAGE_BUFFER>(body.data())->MessageHead);
  const auto status = DnsExtractRecordsFromMessage_W(
      reinterpret_cast<PDNS_MESSAGE_BUFFER>(body.data()), static_cast<WORD>(body.size()), &records);
  struct FreeRecords {
    PDNS_RECORD value;
    ~FreeRecords() { if (value) DnsRecordListFree(value, DnsFreeRecordList); }
  } cleanup{records};
  if (status != ERROR_SUCCESS) return {};
  std::vector<IN_ADDR> addresses;
  for (auto* record = records; record && addresses.size() < 32; record = record->pNext) {
    if (record->Flags.S.Section == DnsSectionAnswer) ttl = std::min(ttl, record->dwTtl);
    if (record->wType == DNS_TYPE_A && record->Flags.S.Section == DnsSectionAnswer &&
        UsableIpv4(record->Data.A.IpAddress)) {
      IN_ADDR address{};
      address.s_addr = record->Data.A.IpAddress;
      addresses.push_back(address);
    }
  }
  return addresses;
}
}  // namespace physical_tcp_latency
