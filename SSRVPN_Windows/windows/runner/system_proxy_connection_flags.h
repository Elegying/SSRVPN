#ifndef SSRVPN_SYSTEM_PROXY_CONNECTION_FLAGS_H_
#define SSRVPN_SYSTEM_PROXY_CONNECTION_FLAGS_H_

#include <windows.h>
#include <wininet.h>

// Never call global WinINet APIs from the registry-sandbox fault harness.
inline bool ReadProxyConnectionFlags(HKEY settings, DWORD* flags) {
#if defined(SSRVPN_SYSTEM_PROXY_RECOVERY_NO_WININET_NOTIFY)
  DWORD type = 0, size = sizeof(*flags);
  const auto status = RegQueryValueExW(settings, L"TestConnectionFlags", nullptr,
      &type, reinterpret_cast<BYTE*>(flags), &size);
  if (status == ERROR_FILE_NOT_FOUND) {
    DWORD enabled = 0, bytes = sizeof(enabled);
    RegQueryValueExW(settings, L"ProxyEnable", nullptr, &type,
        reinterpret_cast<BYTE*>(&enabled), &bytes);
    *flags = PROXY_TYPE_DIRECT | (enabled == 1 ? PROXY_TYPE_PROXY : 0);
    return true;
  }
  return status == ERROR_SUCCESS && type == REG_DWORD && size == sizeof(*flags);
#else
  (void)settings;
  INTERNET_PER_CONN_OPTIONW option{};
  option.dwOption = INTERNET_PER_CONN_FLAGS_UI;
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = sizeof(list);
  list.dwOptionCount = 1;
  list.pOptions = &option;
  DWORD size = sizeof(list);
  if (!InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                            &list, &size)) {
    if (GetLastError() != ERROR_INVALID_PARAMETER) return false;
    option.dwOption = INTERNET_PER_CONN_FLAGS;
    size = sizeof(list);
    if (!InternetQueryOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                              &list, &size)) return false;
  }
  *flags = option.Value.dwValue;
  return *flags <= 15;
#endif
}

inline bool WriteProxyConnectionFlags(HKEY settings, DWORD flags) {
  if (flags > 15) return false;
#if defined(SSRVPN_SYSTEM_PROXY_RECOVERY_NO_WININET_NOTIFY)
  DWORD fail = 0, size = sizeof(fail);
  if (RegQueryValueExW(settings, L"TestFailFlagsWrite", nullptr, nullptr,
      reinterpret_cast<BYTE*>(&fail), &size) == ERROR_SUCCESS && fail != 0) return false;
  return RegSetValueExW(settings, L"TestConnectionFlags", 0, REG_DWORD,
      reinterpret_cast<const BYTE*>(&flags), sizeof(flags)) == ERROR_SUCCESS;
#else
  HKEY policy = nullptr;
  const auto policy_status = RegOpenKeyExW(HKEY_LOCAL_MACHINE,
      L"SOFTWARE\\Policies\\Microsoft\\Windows\\CurrentVersion\\Internet Settings",
      0, KEY_QUERY_VALUE | KEY_WOW64_64KEY, &policy);
  if (policy_status != ERROR_FILE_NOT_FOUND && policy_status != ERROR_SUCCESS) return false;
  if (policy_status == ERROR_SUCCESS) {
    DWORD value = 0, type = 0, size = sizeof(value);
    const auto status = RegQueryValueExW(policy, L"ProxySettingsPerUser", nullptr,
        &type, reinterpret_cast<BYTE*>(&value), &size);
    RegCloseKey(policy);
    if (status != ERROR_FILE_NOT_FOUND &&
        (status != ERROR_SUCCESS || type != REG_DWORD || size != sizeof(value) || value != 1)) return false;
  }
  INTERNET_PER_CONN_OPTIONW option{};
  option.dwOption = INTERNET_PER_CONN_FLAGS;
  option.Value.dwValue = flags;
  INTERNET_PER_CONN_OPTION_LISTW list{};
  list.dwSize = sizeof(list);
  list.dwOptionCount = 1;
  list.pOptions = &option;
  if (!InternetSetOptionW(nullptr, INTERNET_OPTION_PER_CONNECTION_OPTION,
                          &list, sizeof(list))) return false;
  if (!InternetSetOptionW(nullptr, INTERNET_OPTION_SETTINGS_CHANGED, nullptr, 0) ||
      !InternetSetOptionW(nullptr, INTERNET_OPTION_REFRESH, nullptr, 0)) return false;
  DWORD actual = 0;
  return ReadProxyConnectionFlags(settings, &actual) && actual == flags;
#endif
}
#endif
