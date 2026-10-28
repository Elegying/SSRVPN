#include <windows.h>

#include <cwchar>
#include <filesystem>
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
    // Volatile creation also creates missing parents as volatile. Keep the
    // entire sandbox outside the application's persistent registry namespace.
    path_ = L"SSRVPNNativeRecoveryTests-" +
            std::to_wstring(GetCurrentProcessId()) + L"-" +
            std::to_wstring(GetTickCount64());
    DWORD disposition = 0;
    const LSTATUS created = RegCreateKeyExW(HKEY_CURRENT_USER, path_.c_str(), 0, nullptr,
                        REG_OPTION_VOLATILE, KEY_ALL_ACCESS, nullptr, &root_,
                        &disposition);
    if (created != ERROR_SUCCESS || disposition != REG_CREATED_NEW_KEY) {
      if (root_ != nullptr) RegCloseKey(root_);
      root_ = nullptr;
      path_.clear();
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

std::wstring ApplicationRegistryFingerprint(const wchar_t* path) {
  HKEY key = nullptr;
  const LSTATUS opened = RegOpenKeyExW(HKEY_CURRENT_USER, path, 0, KEY_READ, &key);
  if (opened == ERROR_FILE_NOT_FOUND) return L"absent";
  if (opened != ERROR_SUCCESS) return {};
  DWORD children = 0, values = 0;
  FILETIME written = {};
  const LSTATUS queried = RegQueryInfoKeyW(key, nullptr, nullptr, nullptr,
      &children, nullptr, nullptr, &values, nullptr, nullptr, nullptr, &written);
  RegCloseKey(key);
  if (queried != ERROR_SUCCESS) return {};
  return std::to_wstring(children) + L":" + std::to_wstring(values) + L":" +
         std::to_wstring(written.dwHighDateTime) + L":" +
         std::to_wstring(written.dwLowDateTime);
}

bool TestSandboxLeavesApplicationNamespaceUnchanged() {
  constexpr const wchar_t* paths[] = {
      L"Software\\SSRVPN", L"Software\\SSRVPN\\NativeRecoveryTests"};
  std::wstring before[2];
  for (int i = 0; i < 2; ++i) {
    before[i] = ApplicationRegistryFingerprint(paths[i]);
    if (before[i].empty()) return false;
  }
  {
    RegistrySandbox sandbox;
    if (!sandbox.Initialize()) return false;
    HKEY fixture = nullptr;
    if (!CreateKey(kBackupPath, &fixture)) return false;
    RegCloseKey(fixture);
  }
  for (int i = 0; i < 2; ++i) {
    if (ApplicationRegistryFingerprint(paths[i]) != before[i]) return false;
  }
  return true;
}

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

class RecoveryFiles final {
 public:
  RecoveryFiles() {
    wchar_t temporary[MAX_PATH] = {}, previous[32768] = {};
    GetTempPathW(MAX_PATH, temporary);
    GetEnvironmentVariableW(L"LOCALAPPDATA", previous, 32768);
    previous_ = previous;
    root_ = std::filesystem::path(temporary) /
        (L"SSRVPN 用户's folder " + std::to_wstring(GetCurrentProcessId()));
    runtime_ = root_ / L"SSRVPN" / L"runtime";
    std::filesystem::create_directories(runtime_);
    SetEnvironmentVariableW(L"LOCALAPPDATA", root_.c_str());
    snapshot = runtime_ / L"system_proxy_backup.json";
    HANDLE file = CreateFileW(snapshot.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) throw std::runtime_error("snapshot fixture failed");
    CloseHandle(file);
  }
  ~RecoveryFiles() {
    SetEnvironmentVariableW(L"LOCALAPPDATA", previous_.empty() ? nullptr : previous_.c_str());
    std::error_code error;
    std::filesystem::remove_all(root_, error);
  }
  std::filesystem::path snapshot;
 private:
  std::filesystem::path root_, runtime_;
  std::wstring previous_;
};

bool TestApplicationRecovery(int scenario) {
  RegistrySandbox sandbox;
  RecoveryFiles files;
  if (!sandbox.Initialize() || !SeedOwnedSettings()) return false;
  // No native journal: do not discard the only remaining legacy JSON backup.
  if (scenario == 0) {
    return RecoverWindowsProxyForApplication() == -1 &&
           std::filesystem::exists(files.snapshot);
  }
  if (!SeedJournal(false) || !SeedRunOnce()) return false;
  if (scenario == 1) {
    WindowsProxyTransactionLock held;
    const auto before = GetTickCount64();
    return held.acquired() && RecoverWindowsProxyForApplication() == 0 &&
           GetTickCount64() - before < 1000 &&
           std::filesystem::exists(files.snapshot);
  }
  if (scenario == 2) {
    SetFileAttributesW(files.snapshot.c_str(), FILE_ATTRIBUTE_READONLY);
    const int pending = RecoverWindowsProxyForApplication();
    const bool preserved = std::filesystem::exists(files.snapshot);
    SetFileAttributesW(files.snapshot.c_str(), FILE_ATTRIBUTE_NORMAL);
    return pending == 2 && preserved &&
           RecoverWindowsProxyForApplication() == 1 &&
           !std::filesystem::exists(files.snapshot);
  }
  if (scenario == 3 || scenario == 4) {
    HKEY settings = nullptr;
    if (!CreateKey(kInternetSettingsPath, &settings)) return false;
    const bool written = scenario == 3
        ? SetString(settings, L"ProxyServer", L"external.example:8080")
        : SetString(settings, L"AutoConfigURL", L"https://external.example/proxy.pac");
    RegCloseKey(settings);
    if (!written || RecoverWindowsProxyForApplication() != 5) return false;
    if (!CreateKey(kInternetSettingsPath, &settings)) return false;
    wchar_t buffer[256] = {}; DWORD bytes = sizeof(buffer), type = 0;
    const bool retained = RegQueryValueExW(settings,
        scenario == 3 ? L"ProxyServer" : L"AutoConfigURL", nullptr, &type,
        reinterpret_cast<BYTE*>(buffer), &bytes) == ERROR_SUCCESS &&
        std::wstring(buffer) == (scenario == 3 ? L"external.example:8080"
            : L"https://external.example/proxy.pac");
    RegCloseKey(settings);
    return retained && !std::filesystem::exists(files.snapshot);
  }
  return RecoverWindowsProxyForApplication() == 1 &&
         !std::filesystem::exists(files.snapshot) && KeyIsMissing(kBackupPath) &&
         NamedValueIsMissing(kRunOncePath, kRecoveryRunOnceName);
}

bool TestConnectionFlagsRecovery(bool user_changed, bool legacy) {
  RegistrySandbox sandbox;
  if (!sandbox.Initialize() || !SeedOwnedSettings() || !SeedJournal(false)) return false;
  HKEY settings = nullptr, backup = nullptr;
  if (!CreateKey(kInternetSettingsPath, &settings) || !CreateKey(kBackupPath, &backup)) return false;
  // The UI changed, but the legacy AutoDetect DWORD remains zero.
  const DWORD live = user_changed ? 11 : 3;
  bool ok = SetDword(settings, L"TestConnectionFlags", live);
  if (!legacy) ok = ok && SetDword(backup, L"OriginalConnectionFlags", 9);
  RegCloseKey(settings);
  RegCloseKey(backup);
  if (!ok || !RestoreOwnedWindowsProxy()) return false;
  if (!CreateKey(kInternetSettingsPath, &settings)) return false;
  DWORD actual = 0;
  ok = ReadDword(settings, L"TestConnectionFlags", &actual) &&
       actual == (user_changed || !legacy ? 9u : 1u);
  RegCloseKey(settings);
  return ok && KeyIsMissing(kBackupPath);
}

bool TestRecoveryWaitsForSurvivingCommand() {
  RecoveryFiles files;
  const auto path = files.snapshot.parent_path() / L"system_proxy_transaction.lock.command";
  HANDLE command = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (command == INVALID_HANDLE_VALUE) return false;
  OVERLAPPED overlap{};
  if (!LockFileEx(command, LOCKFILE_EXCLUSIVE_LOCK, 0, 1, 0, &overlap)) {
    CloseHandle(command); return false;
  }
  bool blocked;
  {
    WindowsProxyTransactionLock recovery(false);
    blocked = !recovery.acquired();
  }
  UnlockFileEx(command, 0, 1, 0, &overlap);
  CloseHandle(command);
  WindowsProxyTransactionLock retry(false);
  return blocked && retry.acquired();
}

bool TestFailedConnectionFlagsRestoreRetainsJournal() {
  RegistrySandbox sandbox;
  if (!sandbox.Initialize() || !SeedOwnedSettings() || !SeedJournal(false)) return false;
  HKEY settings = nullptr, backup = nullptr;
  if (!CreateKey(kInternetSettingsPath, &settings) || !CreateKey(kBackupPath, &backup)) return false;
  bool ok = SetDword(settings, L"TestConnectionFlags", 3) &&
      SetDword(settings, L"TestFailFlagsWrite", 1) &&
      SetDword(backup, L"OriginalConnectionFlags", 9);
  RegCloseKey(backup);
  if (ok) ok = !RestoreOwnedWindowsProxy() && !KeyIsMissing(kBackupPath) &&
               !IsOwnedWindowsProxySafeToStop();
  ok = ok && SetDword(settings, L"TestFailFlagsWrite", 0);
  RegCloseKey(settings);
  return ok && RestoreOwnedWindowsProxy() && KeyIsMissing(kBackupPath);
}

bool TestBypassEditStillRestoresOwnedAutoDetectBit() {
  RegistrySandbox sandbox;
  if (!sandbox.Initialize() || !SeedOwnedSettings() || !SeedJournal(false)) return false;
  HKEY settings = nullptr, backup = nullptr;
  if (!CreateKey(kInternetSettingsPath, &settings) || !CreateKey(kBackupPath, &backup)) return false;
  bool ok = SetDword(settings, L"TestConnectionFlags", 3) &&
      SetString(settings, L"ProxyOverride", L"company.example") &&
      SetDword(backup, L"OriginalConnectionFlags", 9);
  RegCloseKey(backup);
  ok = ok && RestoreOwnedWindowsProxy();
  DWORD flags = 0;
  wchar_t bypass[128] = {}; DWORD bytes = sizeof(bypass), type = 0;
  ok = ok && ReadDword(settings, L"TestConnectionFlags", &flags) && flags == 9 &&
      RegQueryValueExW(settings, L"ProxyOverride", nullptr, &type,
          reinterpret_cast<BYTE*>(bypass), &bytes) == ERROR_SUCCESS &&
      std::wstring(bypass) == L"company.example";
  RegCloseKey(settings);
  return ok;
}

}  // namespace

int wmain() {
  if (!TestBypassEditStillRestoresOwnedAutoDetectBit()) {
    std::wcerr << L"bypass edit lost auto-detect recovery\n";
    return 1;
  }
  if (!TestFailedConnectionFlagsRestoreRetainsJournal()) {
    std::wcerr << L"failed LAN restoration lost recovery state\n";
    return 1;
  }
  if (!TestRecoveryWaitsForSurvivingCommand()) {
    std::wcerr << L"surviving proxy command lock test failed\n";
    return 1;
  }
  for (const bool changed : {false, true}) {
    for (const bool legacy : {false, true}) {
      if (!TestConnectionFlagsRecovery(changed, legacy)) {
        std::wcerr << L"LAN connection flags recovery failed\n";
        return 1;
      }
    }
  }
  if (!TestSandboxLeavesApplicationNamespaceUnchanged()) {
    std::wcerr << L"registry sandbox modified the application namespace\n";
    return 1;
  }
  for (int scenario = 0; scenario < 6; ++scenario) {
    if (!TestApplicationRecovery(scenario)) {
      std::wcerr << L"application recovery scenario failed: " << scenario << L"\n";
      return 1;
    }
  }
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
