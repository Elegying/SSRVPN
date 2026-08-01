#include <windows.h>

#include <cwchar>
#include <iostream>
#include <string>

#include "system_proxy_recovery.h"

namespace {

constexpr wchar_t kBackupPath[] = L"Software\\SSRVPN\\RuntimeProxyBackup";
constexpr wchar_t kInternetSettingsPath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
constexpr wchar_t kRunOncePath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce";
constexpr wchar_t kRecoveryRunOnceName[] = L"SSRVPNProxyRecovery";
constexpr wchar_t kOwnedProxyServer[] = L"127.0.0.1:7890";
constexpr wchar_t kOwnedProxyOverride[] =
    L"<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;"
    L"172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;"
    L"172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*";

bool CreateKey(const wchar_t* path, HKEY* key) {
  return RegCreateKeyExW(HKEY_CURRENT_USER, path, 0, nullptr,
                         REG_OPTION_VOLATILE, KEY_ALL_ACCESS, nullptr, key,
                         nullptr) == ERROR_SUCCESS;
}

bool SetDword(HKEY key, const wchar_t* name, DWORD value) {
  return RegSetValueExW(key, name, 0, REG_DWORD,
                        reinterpret_cast<const BYTE*>(&value),
                        sizeof(value)) == ERROR_SUCCESS;
}

bool SetString(HKEY key, const wchar_t* name, const wchar_t* value) {
  const DWORD size = static_cast<DWORD>(
      (std::wcslen(value) + 1) * sizeof(wchar_t));
  return RegSetValueExW(key, name, 0, REG_SZ,
                        reinterpret_cast<const BYTE*>(value),
                        size) == ERROR_SUCCESS;
}

bool ReadDword(HKEY key, const wchar_t* name, DWORD* value) {
  DWORD type = 0;
  DWORD size = sizeof(*value);
  return RegQueryValueExW(key, name, nullptr, &type,
                          reinterpret_cast<BYTE*>(value), &size) ==
             ERROR_SUCCESS &&
         type == REG_DWORD && size == sizeof(*value);
}

bool ValueIsMissing(HKEY key, const wchar_t* name) {
  return RegQueryValueExW(key, name, nullptr, nullptr, nullptr, nullptr) ==
         ERROR_FILE_NOT_FOUND;
}

bool KeyIsMissing(const wchar_t* path) {
  HKEY key = nullptr;
  const LSTATUS status =
      RegOpenKeyExW(HKEY_CURRENT_USER, path, 0, KEY_READ, &key);
  if (status == ERROR_SUCCESS) RegCloseKey(key);
  return status == ERROR_FILE_NOT_FOUND;
}

bool NamedValueIsMissing(const wchar_t* path, const wchar_t* name) {
  HKEY key = nullptr;
  const LSTATUS status =
      RegOpenKeyExW(HKEY_CURRENT_USER, path, 0, KEY_READ, &key);
  if (status == ERROR_FILE_NOT_FOUND) return true;
  if (status != ERROR_SUCCESS) return false;
  const bool missing = ValueIsMissing(key, name);
  RegCloseKey(key);
  return missing;
}

class RegistrySandbox final {
 public:
  RegistrySandbox() = default;
  ~RegistrySandbox() {
    if (overridden_) {
      RegOverridePredefKey(HKEY_CURRENT_USER, nullptr);
    }
    if (root_ != nullptr) RegCloseKey(root_);
    if (!path_.empty()) {
      RegDeleteTreeW(HKEY_CURRENT_USER, path_.c_str());
    }
  }

  RegistrySandbox(const RegistrySandbox&) = delete;
  RegistrySandbox& operator=(const RegistrySandbox&) = delete;

  bool Initialize() {
    path_ = L"Software\\SSRVPN\\NativeRecoveryTests\\" +
            std::to_wstring(GetCurrentProcessId()) + L"-" +
            std::to_wstring(GetTickCount64());
    if (RegCreateKeyExW(HKEY_CURRENT_USER, path_.c_str(), 0, nullptr,
                        REG_OPTION_VOLATILE, KEY_ALL_ACCESS, nullptr, &root_,
                        nullptr) != ERROR_SUCCESS) {
      return false;
    }
    if (RegOverridePredefKey(HKEY_CURRENT_USER, root_) != ERROR_SUCCESS) {
      return false;
    }
    overridden_ = true;
    return true;
  }

 private:
  HKEY root_ = nullptr;
  std::wstring path_;
  bool overridden_ = false;
};

bool SeedOwnedSettings() {
  HKEY settings = nullptr;
  if (!CreateKey(kInternetSettingsPath, &settings)) return false;
  const bool written = SetDword(settings, L"ProxyEnable", 1) &&
                       SetString(settings, L"ProxyServer", kOwnedProxyServer) &&
                       SetString(settings, L"ProxyOverride", kOwnedProxyOverride) &&
                       SetDword(settings, L"AutoDetect", 0);
  RegCloseKey(settings);
  return written;
}

bool SeedRunOnce() {
  HKEY run_once = nullptr;
  if (!CreateKey(kRunOncePath, &run_once)) return false;
  const bool written = SetString(run_once, kRecoveryRunOnceName,
                                 L"synthetic recovery command");
  RegCloseKey(run_once);
  return written;
}

bool SeedJournal(bool malformed_original_proxy_enable) {
  HKEY backup = nullptr;
  if (!CreateKey(kBackupPath, &backup)) return false;
  bool written = SetString(backup, L"OwnedProxyServer", kOwnedProxyServer) &&
                 SetString(backup, L"OwnedProxyOverride", kOwnedProxyOverride) &&
                 SetDword(backup, L"Valid", 1) &&
                 SetDword(backup, L"RestoreInProgress", 0) &&
                 SetDword(backup, L"ActivationInProgress", 0) &&
                 SetDword(backup, L"EndpointRestoreInProgress", 0) &&
                 SetDword(backup, L"HasProxyEnable", 1) &&
                 SetDword(backup, L"HasProxyServer", 0) &&
                 SetDword(backup, L"HasProxyOverride", 0) &&
                 SetDword(backup, L"HasAutoConfigURL", 0) &&
                 SetDword(backup, L"HasAutoDetect", 1) &&
                 SetDword(backup, L"OriginalAutoDetect", 0);
  written = written &&
            (malformed_original_proxy_enable
                 ? SetString(backup, L"OriginalProxyEnable", L"not-a-dword")
                 : SetDword(backup, L"OriginalProxyEnable", 0));
  RegCloseKey(backup);
  return written;
}

bool TestValidJournalRestoresOriginalState() {
  RegistrySandbox sandbox;
  if (!sandbox.Initialize() || !SeedOwnedSettings() ||
      !SeedJournal(false) || !SeedRunOnce()) {
    return false;
  }

  if (!RestoreOwnedWindowsProxy()) return false;

  HKEY settings = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kInternetSettingsPath, 0, KEY_READ,
                    &settings) != ERROR_SUCCESS) {
    return false;
  }
  DWORD proxy_enable = 1;
  const bool restored = ReadDword(settings, L"ProxyEnable", &proxy_enable) &&
                        proxy_enable == 0 &&
                        ValueIsMissing(settings, L"ProxyServer") &&
                        ValueIsMissing(settings, L"ProxyOverride");
  RegCloseKey(settings);
  return restored && KeyIsMissing(kBackupPath) &&
         NamedValueIsMissing(kRunOncePath, kRecoveryRunOnceName);
}

bool TestMalformedJournalDisablesOwnedEndpoint() {
  RegistrySandbox sandbox;
  if (!sandbox.Initialize() || !SeedOwnedSettings() || !SeedJournal(true)) {
    return false;
  }

  if (RestoreOwnedWindowsProxy()) return false;

  HKEY settings = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kInternetSettingsPath, 0, KEY_READ,
                    &settings) != ERROR_SUCCESS) {
    return false;
  }
  DWORD proxy_enable = 1;
  const bool endpoint_disabled =
      ReadDword(settings, L"ProxyEnable", &proxy_enable) && proxy_enable == 0;
  RegCloseKey(settings);
  return endpoint_disabled && !KeyIsMissing(kBackupPath);
}

}  // namespace

int wmain() {
  if (!TestValidJournalRestoresOriginalState()) {
    std::wcerr << L"valid journal recovery test failed\n";
    return 1;
  }
  if (!TestMalformedJournalDisablesOwnedEndpoint()) {
    std::wcerr << L"malformed journal fail-safe test failed\n";
    return 1;
  }
  std::wcout << L"Windows native proxy recovery tests passed.\n";
  return 0;
}
