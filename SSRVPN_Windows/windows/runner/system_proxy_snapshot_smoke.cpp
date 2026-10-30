#include "system_proxy_snapshot.h"

#include <chrono>
#include <iostream>

#if defined(SSRVPN_SYSTEM_PROXY_RECOVERY_NO_WININET_NOTIFY)
#error The read-only smoke must exercise the real WinINet APIs.
#endif

int wmain() {
  // Prerequisites: initialized current-user Internet Settings and permission
  // to use per-user proxy settings (the normal hosted Windows CI account).
  // A launcher is deliberately not required. Never create/fix registry values
  // or call InternetSetOption to make this smoke pass.
  const auto started = std::chrono::steady_clock::now();
  const auto read = ReadWindowsProxySnapshot(false);
  const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
      std::chrono::steady_clock::now() - started).count();
  const auto& s = read.snapshot;
  const bool valid = read.status == ProxySnapshotStatus::ok &&
      s.proxy_enable <= 1 && s.auto_detect <= 1 && s.connection_flags <= 15 &&
      (s.has_proxy_enable || s.proxy_enable == 0) &&
      (s.has_auto_detect || s.auto_detect == 0) &&
      (s.has_proxy_server || s.proxy_server.empty()) &&
      (s.has_proxy_override || s.proxy_override.empty()) &&
      (s.has_auto_config_url || s.auto_config_url.empty());
  // Never print proxy/PAC URLs, bypass lists, registry snapshots or policies.
  if (!valid) {
    std::wcerr << L"Native proxy read-only smoke failed; requires initialized "
                  L"current-user Internet Settings and per-user proxy policy.\n";
    return 1;
  }
  std::wcout << L"Native proxy read-only smoke passed in " << elapsed << L" ms.\n";
  return 0;
}
