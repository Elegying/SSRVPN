#ifndef RUNNER_SYSTEM_PROXY_SNAPSHOT_H_
#define RUNNER_SYSTEM_PROXY_SNAPSHOT_H_

#include <windows.h>
#include <string>

enum class ProxySnapshotStatus { ok = 0, policy_denied = 1,
                                 guardian_missing = 2, unavailable = 3 };
struct WindowsProxySnapshot {
  bool has_proxy_enable = false, has_proxy_server = false;
  bool has_proxy_override = false, has_auto_config_url = false;
  bool has_auto_detect = false;
  DWORD proxy_enable = 0, auto_detect = 0, connection_flags = 0;
  std::wstring proxy_server, proxy_override, auto_config_url;
};
struct WindowsProxySnapshotResult {
  ProxySnapshotStatus status = ProxySnapshotStatus::unavailable;
  WindowsProxySnapshot snapshot;
};

// Read-only: caller serializes against its transaction. Never acquire the
// Dart-held file lock here and never create registry keys or alter LAN flags.
WindowsProxySnapshotResult ReadWindowsProxySnapshot(bool require_guardian);
bool IsWindowsProxyGuardianReady();

#if defined(SSRVPN_SYSTEM_PROXY_RECOVERY_NO_WININET_NOTIFY)
// Sandboxed registry handles let native tests avoid machine/user policy writes.
WindowsProxySnapshotResult ReadWindowsProxySnapshotForTesting(
    HKEY policy_root, HKEY settings, bool require_guardian,
    const wchar_t* guardian_name);
#endif
#endif
