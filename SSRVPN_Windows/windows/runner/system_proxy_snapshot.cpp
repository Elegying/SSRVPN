#include "system_proxy_snapshot.h"
#include "system_proxy_connection_flags.h"

#include <vector>

namespace {
constexpr wchar_t kSettings[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
constexpr wchar_t kPolicy[] =
    L"SOFTWARE\\Policies\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
constexpr wchar_t kGuardian[] = L"Local\\SSRVPN_Windows_LauncherGuardian";

ProxySnapshotStatus CheckPolicy(HKEY root) {
  HKEY policy = nullptr;
  const auto opened = RegOpenKeyExW(root, kPolicy, 0,
                                    KEY_QUERY_VALUE | KEY_WOW64_64KEY, &policy);
  if (opened == ERROR_FILE_NOT_FOUND) return ProxySnapshotStatus::ok;
  if (opened != ERROR_SUCCESS) return ProxySnapshotStatus::unavailable;
  DWORD value = 0, type = 0, size = sizeof(value);
  const auto read = RegQueryValueExW(policy, L"ProxySettingsPerUser", nullptr,
      &type, reinterpret_cast<BYTE*>(&value), &size);
  RegCloseKey(policy);
  if (read == ERROR_FILE_NOT_FOUND) return ProxySnapshotStatus::ok;
  if (read != ERROR_SUCCESS) return ProxySnapshotStatus::unavailable;
  return type == REG_DWORD && size == sizeof(value) && value == 1
      ? ProxySnapshotStatus::ok : ProxySnapshotStatus::policy_denied;
}

bool GuardianReady(const wchar_t* name) {
  HANDLE guardian = OpenMutexW(SYNCHRONIZE | MUTEX_MODIFY_STATE, FALSE, name);
  if (guardian == nullptr) return false;
  const auto result = WaitForSingleObject(guardian, 0);
  // Acquired or abandoned means no live launcher owns it. Release only a
  // handle actually acquired by this thread, just like the PowerShell probe.
  if (result == WAIT_OBJECT_0 || result == WAIT_ABANDONED) ReleaseMutex(guardian);
  CloseHandle(guardian);
  return result == WAIT_TIMEOUT;
}

bool ReadFlag(HKEY key, const wchar_t* name, bool* present, DWORD* value) {
  DWORD type = 0, size = sizeof(*value);
  const auto read = RegQueryValueExW(key, name, nullptr, &type,
                                    reinterpret_cast<BYTE*>(value), &size);
  if (read == ERROR_FILE_NOT_FOUND) { *present = false; *value = 0; return true; }
  if (read != ERROR_SUCCESS || type != REG_DWORD || size != sizeof(*value) ||
      *value > 1) return false;
  *present = true;
  return true;
}

bool ReadText(HKEY key, const wchar_t* name, bool* present, std::wstring* value) {
  DWORD type = 0, size = 0;
  const auto read = RegQueryValueExW(key, name, nullptr, &type, nullptr, &size);
  if (read == ERROR_FILE_NOT_FOUND) { *present = false; value->clear(); return true; }
  if (read != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ) ||
      size < sizeof(wchar_t) || size > 65536 || size % sizeof(wchar_t) != 0)
    return false;
  std::vector<wchar_t> data(size / sizeof(wchar_t));
  DWORD actual = size;
  if (RegQueryValueExW(key, name, nullptr, &type,
      reinterpret_cast<BYTE*>(data.data()), &actual) != ERROR_SUCCESS ||
      actual != size || (type != REG_SZ && type != REG_EXPAND_SZ) ||
      data.back() != L'\0') return false;
  // Do not truncate a malformed embedded-NUL registry string on restoration.
  for (size_t i = 0; i + 1 < data.size(); ++i) if (data[i] == L'\0') return false;
  if (data.size() > 1 && WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
      data.data(), static_cast<int>(data.size() - 1), nullptr, 0, nullptr, nullptr) <= 0)
    return false;
  *present = true;
  value->assign(data.data(), data.size() - 1);
  return true;
}

WindowsProxySnapshotResult ReadCheckedSnapshot(HKEY policy_root, HKEY settings,
    bool guardian_required, const wchar_t* guardian_name) {
  WindowsProxySnapshotResult result;
  result.status = CheckPolicy(policy_root);
  if (result.status != ProxySnapshotStatus::ok) return result;
  if (guardian_required && !GuardianReady(guardian_name)) {
    result.status = ProxySnapshotStatus::guardian_missing;
    return result;
  }
  result.status = ProxySnapshotStatus::unavailable;
  auto& s = result.snapshot;
  if (settings == nullptr ||
      !ReadFlag(settings, L"ProxyEnable", &s.has_proxy_enable, &s.proxy_enable) ||
      !ReadFlag(settings, L"AutoDetect", &s.has_auto_detect, &s.auto_detect) ||
      !ReadText(settings, L"ProxyServer", &s.has_proxy_server, &s.proxy_server) ||
      !ReadText(settings, L"ProxyOverride", &s.has_proxy_override, &s.proxy_override) ||
      !ReadText(settings, L"AutoConfigURL", &s.has_auto_config_url, &s.auto_config_url) ||
      !ReadProxyConnectionFlags(settings, &s.connection_flags) ||
      s.connection_flags > 15) return result;
  result.status = ProxySnapshotStatus::ok;
  return result;
}
}  // namespace

bool IsWindowsProxyGuardianReady() { return GuardianReady(kGuardian); }

WindowsProxySnapshotResult ReadWindowsProxySnapshot(bool require_guardian) {
  HKEY settings = nullptr;
  RegOpenKeyExW(HKEY_CURRENT_USER, kSettings, 0, KEY_QUERY_VALUE, &settings);
  auto result = ReadCheckedSnapshot(HKEY_LOCAL_MACHINE, settings,
                                    require_guardian, kGuardian);
  if (settings != nullptr) RegCloseKey(settings);
  return result;
}

#if defined(SSRVPN_SYSTEM_PROXY_RECOVERY_NO_WININET_NOTIFY)
WindowsProxySnapshotResult ReadWindowsProxySnapshotForTesting(
    HKEY policy_root, HKEY settings, bool require_guardian,
    const wchar_t* guardian_name) {
  return ReadCheckedSnapshot(policy_root, settings, require_guardian, guardian_name);
}
#endif
