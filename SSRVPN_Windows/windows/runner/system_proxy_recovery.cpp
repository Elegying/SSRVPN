#include "system_proxy_recovery.h"

#include <windows.h>
#include <wininet.h>

#include <string>
#include <vector>

namespace {

constexpr wchar_t kBackupPath[] = L"Software\\SSRVPN\\RuntimeProxyBackup";
constexpr wchar_t kInternetSettingsPath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";

bool ReadDword(HKEY key, const wchar_t* name, DWORD* value) {
  DWORD type = 0;
  DWORD size = sizeof(*value);
  return RegQueryValueExW(key, name, nullptr, &type,
                          reinterpret_cast<BYTE*>(value), &size) ==
             ERROR_SUCCESS &&
         type == REG_DWORD && size == sizeof(*value);
}

bool ReadString(HKEY key, const wchar_t* name, std::wstring* value) {
  DWORD type = 0;
  DWORD size = 0;
  if (RegQueryValueExW(key, name, nullptr, &type, nullptr, &size) !=
          ERROR_SUCCESS ||
      (type != REG_SZ && type != REG_EXPAND_SZ) || size < sizeof(wchar_t)) {
    return false;
  }
  std::vector<wchar_t> buffer(size / sizeof(wchar_t) + 1, L'\0');
  if (RegQueryValueExW(key, name, nullptr, &type,
                       reinterpret_cast<BYTE*>(buffer.data()), &size) !=
      ERROR_SUCCESS) {
    return false;
  }
  *value = buffer.data();
  return true;
}

bool ValueExists(HKEY key, const wchar_t* name) {
  const LSTATUS status =
      RegQueryValueExW(key, name, nullptr, nullptr, nullptr, nullptr);
  return status == ERROR_SUCCESS || status == ERROR_MORE_DATA;
}

bool SetDword(HKEY key, const wchar_t* name, DWORD value) {
  return RegSetValueExW(key, name, 0, REG_DWORD,
                        reinterpret_cast<const BYTE*>(&value),
                        sizeof(value)) == ERROR_SUCCESS;
}

bool SetString(HKEY key, const wchar_t* name, const std::wstring& value) {
  const DWORD size =
      static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
  return RegSetValueExW(key, name, 0, REG_SZ,
                        reinterpret_cast<const BYTE*>(value.c_str()), size) ==
         ERROR_SUCCESS;
}

bool DeleteValueIfPresent(HKEY key, const wchar_t* name) {
  const LSTATUS status = RegDeleteValueW(key, name);
  return status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND;
}

bool ReadOptionalString(HKEY backup, const wchar_t* presence_name,
                        const wchar_t* backup_name, DWORD* present,
                        std::wstring* value) {
  if (!ReadDword(backup, presence_name, present)) return false;
  if (*present == 0) {
    value->clear();
    return true;
  }
  return ReadString(backup, backup_name, value);
}

bool RestorePreparedString(HKEY settings, DWORD present,
                           const std::wstring& value,
                           const wchar_t* target_name) {
  if (present == 0) {
    return DeleteValueIfPresent(settings, target_name);
  }
  return SetString(settings, target_name, value);
}

void NotifyWinInet() {
  InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0);
  InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0);
}

}  // namespace

bool RestoreOwnedWindowsProxy() noexcept {
  HKEY backup = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kBackupPath, 0,
                    KEY_READ | KEY_SET_VALUE,
                    &backup) != ERROR_SUCCESS) {
    return false;
  }

  DWORD valid = 0;
  std::wstring owned_server;
  std::wstring owned_override;
  const bool backup_valid = ReadDword(backup, L"Valid", &valid) && valid == 1 &&
                            ReadString(backup, L"OwnedProxyServer",
                                       &owned_server) &&
                            ReadString(backup, L"OwnedProxyOverride",
                                       &owned_override);
  if (!backup_valid) {
    RegCloseKey(backup);
    return false;
  }

  HKEY settings = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kInternetSettingsPath, 0,
                    KEY_QUERY_VALUE | KEY_SET_VALUE,
                    &settings) != ERROR_SUCCESS) {
    RegCloseKey(backup);
    return false;
  }

  DWORD proxy_enable = 0;
  DWORD auto_detect = 0;
  DWORD restore_in_progress = 0;
  DWORD activation_in_progress = 0;
  DWORD endpoint_restore_in_progress = 0;
  std::wstring proxy_server;
  std::wstring proxy_override;
  ReadDword(backup, L"RestoreInProgress", &restore_in_progress);
  ReadDword(backup, L"ActivationInProgress", &activation_in_progress);
  ReadDword(backup, L"EndpointRestoreInProgress",
            &endpoint_restore_in_progress);
  const bool endpoint_owned =
      ReadDword(settings, L"ProxyEnable", &proxy_enable) &&
      proxy_enable == 1 &&
      ReadString(settings, L"ProxyServer", &proxy_server) &&
      proxy_server == owned_server;
  const bool owned = endpoint_owned &&
                     ReadString(settings, L"ProxyOverride", &proxy_override) &&
                     proxy_override == owned_override &&
                     ReadDword(settings, L"AutoDetect", &auto_detect) &&
                     auto_detect == 0 &&
                     !ValueExists(settings, L"AutoConfigURL");
  const bool full_restore_pending =
      restore_in_progress == 1 || activation_in_progress == 1;
  if (!owned && !full_restore_pending &&
      (endpoint_owned || endpoint_restore_in_progress == 1)) {
    DWORD original_proxy_enable = 0;
    DWORD has_proxy_server = 0;
    std::wstring original_proxy_server;
    bool endpoint_restored =
        ReadDword(backup, L"OriginalProxyEnable", &original_proxy_enable) &&
        ReadOptionalString(backup, L"HasProxyServer", L"OriginalProxyServer",
                           &has_proxy_server, &original_proxy_server) &&
        (endpoint_restore_in_progress == 1 ||
         SetDword(backup, L"EndpointRestoreInProgress", 1)) &&
        RestorePreparedString(settings, has_proxy_server,
                              original_proxy_server, L"ProxyServer") &&
        SetDword(settings, L"ProxyEnable", original_proxy_enable);
    RegCloseKey(settings);
    RegCloseKey(backup);
    if (!endpoint_restored) return false;
    if (RegDeleteTreeW(HKEY_CURRENT_USER, kBackupPath) != ERROR_SUCCESS) {
      return false;
    }
    NotifyWinInet();
    return true;
  }
  if (!owned && !full_restore_pending) {
    RegCloseKey(settings);
    RegCloseKey(backup);
    RegDeleteTreeW(HKEY_CURRENT_USER, kBackupPath);
    return false;
  }

  DWORD original_proxy_enable = 0;
  DWORD has_proxy_server = 0;
  DWORD has_proxy_override = 0;
  DWORD has_auto_config_url = 0;
  DWORD has_auto_detect = 0;
  DWORD original_auto_detect = 0;
  std::wstring original_proxy_server;
  std::wstring original_proxy_override;
  std::wstring original_auto_config_url;
  const bool snapshot_valid =
      ReadDword(backup, L"OriginalProxyEnable", &original_proxy_enable) &&
      ReadOptionalString(backup, L"HasProxyServer", L"OriginalProxyServer",
                         &has_proxy_server, &original_proxy_server) &&
      ReadOptionalString(backup, L"HasProxyOverride",
                         L"OriginalProxyOverride", &has_proxy_override,
                         &original_proxy_override) &&
      ReadOptionalString(backup, L"HasAutoConfigURL",
                         L"OriginalAutoConfigURL", &has_auto_config_url,
                         &original_auto_config_url) &&
      ReadDword(backup, L"HasAutoDetect", &has_auto_detect) &&
      ReadDword(backup, L"OriginalAutoDetect", &original_auto_detect);

  bool restored = snapshot_valid &&
                  (restore_in_progress == 1 ||
                   SetDword(backup, L"RestoreInProgress", 1));
  if (restored) {
    restored =
        RestorePreparedString(settings, has_proxy_server,
                              original_proxy_server, L"ProxyServer") &&
        RestorePreparedString(settings, has_proxy_override,
                              original_proxy_override, L"ProxyOverride") &&
        RestorePreparedString(settings, has_auto_config_url,
                              original_auto_config_url, L"AutoConfigURL") &&
        (has_auto_detect != 0
             ? SetDword(settings, L"AutoDetect", original_auto_detect)
             : DeleteValueIfPresent(settings, L"AutoDetect")) &&
        SetDword(settings, L"ProxyEnable", original_proxy_enable);
  }

  RegCloseKey(settings);
  RegCloseKey(backup);
  if (!restored) {
    return false;
  }
  if (RegDeleteTreeW(HKEY_CURRENT_USER, kBackupPath) != ERROR_SUCCESS) {
    return false;
  }
  NotifyWinInet();
  return true;
}
