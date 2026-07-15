#include "system_proxy_recovery.h"

#include <windows.h>
#include <wininet.h>

#include <string>
#include <vector>

namespace {

constexpr wchar_t kBackupPath[] = L"Software\\SSRVPN\\RuntimeProxyBackup";
constexpr wchar_t kInternetSettingsPath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
constexpr wchar_t kOwnedProxyOverride[] =
    L"<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;"
    L"172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;"
    L"172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*";

bool IsOwnedProxyServer(const std::wstring& value) {
  constexpr wchar_t prefix[] = L"127.0.0.1:";
  constexpr size_t prefix_length =
      (sizeof(prefix) / sizeof(prefix[0])) - 1;
  if (value.size() <= prefix_length || value.size() > prefix_length + 5 ||
      value.compare(0, prefix_length, prefix) != 0) {
    return false;
  }
  unsigned int port = 0;
  for (size_t index = prefix_length; index < value.size(); ++index) {
    const wchar_t digit = value[index];
    if (digit < L'0' || digit > L'9') return false;
    port = port * 10 + static_cast<unsigned int>(digit - L'0');
  }
  return port >= 1 && port <= 65535;
}

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

bool IsDwordZeroOrAbsent(HKEY key, const wchar_t* name) {
  DWORD type = 0;
  DWORD value = 0;
  DWORD size = sizeof(value);
  const LSTATUS status = RegQueryValueExW(
      key, name, nullptr, &type, reinterpret_cast<BYTE*>(&value), &size);
  return status == ERROR_FILE_NOT_FOUND ||
         (status == ERROR_SUCCESS && type == REG_DWORD &&
          size == sizeof(value) && value == 0);
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

bool DisableOwnedProxyEndpoint(HKEY settings,
                               const std::wstring& owned_server) {
  DWORD proxy_enable = 0;
  std::wstring proxy_server;
  return ReadDword(settings, L"ProxyEnable", &proxy_enable) &&
         proxy_enable == 1 &&
         ReadString(settings, L"ProxyServer", &proxy_server) &&
         proxy_server == owned_server &&
         SetDword(settings, L"ProxyEnable", 0);
}

bool DisableOwnedProxyFingerprint(HKEY settings,
                                  const std::wstring& owned_server,
                                  const std::wstring& owned_override) {
  DWORD proxy_enable = 0;
  std::wstring proxy_server;
  std::wstring proxy_override;
  return ReadDword(settings, L"ProxyEnable", &proxy_enable) &&
         proxy_enable == 1 &&
         ReadString(settings, L"ProxyServer", &proxy_server) &&
         proxy_server == owned_server &&
         ReadString(settings, L"ProxyOverride", &proxy_override) &&
         proxy_override == owned_override &&
         IsDwordZeroOrAbsent(settings, L"AutoDetect") &&
         !ValueExists(settings, L"AutoConfigURL") &&
         SetDword(settings, L"ProxyEnable", 0);
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
  const bool ownership_metadata_valid =
      ReadString(backup, L"OwnedProxyServer", &owned_server) &&
      ReadString(backup, L"OwnedProxyOverride", &owned_override) &&
      IsOwnedProxyServer(owned_server) &&
      owned_override == kOwnedProxyOverride;
  const bool backup_valid = ownership_metadata_valid &&
                            ReadDword(backup, L"Valid", &valid) && valid == 1;
  if (!backup_valid) {
    bool disabled = false;
    HKEY invalid_settings = nullptr;
    if (ownership_metadata_valid &&
        RegOpenKeyExW(HKEY_CURRENT_USER, kInternetSettingsPath, 0,
                      KEY_QUERY_VALUE | KEY_SET_VALUE,
                      &invalid_settings) == ERROR_SUCCESS) {
      disabled = DisableOwnedProxyFingerprint(
          invalid_settings, owned_server, owned_override);
      RegCloseKey(invalid_settings);
    }
    RegCloseKey(backup);
    if (disabled) NotifyWinInet();
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
                     IsDwordZeroOrAbsent(settings, L"AutoDetect") &&
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
    const bool endpoint_disabled =
        !endpoint_restored && DisableOwnedProxyEndpoint(settings, owned_server);
    RegCloseKey(settings);
    RegCloseKey(backup);
    if (!endpoint_restored) {
      if (endpoint_disabled) NotifyWinInet();
      return false;
    }
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

  const bool endpoint_disabled =
      !restored && DisableOwnedProxyEndpoint(settings, owned_server);
  RegCloseKey(settings);
  RegCloseKey(backup);
  if (!restored) {
    if (endpoint_disabled) NotifyWinInet();
    return false;
  }
  if (RegDeleteTreeW(HKEY_CURRENT_USER, kBackupPath) != ERROR_SUCCESS) {
    return false;
  }
  NotifyWinInet();
  return true;
}
