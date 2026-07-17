#include "system_proxy_recovery.h"

#include <windows.h>
#include <wininet.h>

#include <string>
#include <vector>

namespace {

constexpr wchar_t kBackupPath[] = L"Software\\SSRVPN\\RuntimeProxyBackup";
constexpr wchar_t kInternetSettingsPath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings";
constexpr wchar_t kRunOncePath[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce";
constexpr wchar_t kRecoveryRunOnceName[] = L"SSRVPNProxyRecovery";
constexpr wchar_t kProxyTransactionLockFile[] =
    L"system_proxy_transaction.lock";
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

struct OptionalStringValue {
  DWORD present = 0;
  std::wstring value;
};

struct OptionalDwordValue {
  DWORD present = 0;
  DWORD value = 0;
};

struct ProxyStateSnapshot {
  DWORD proxy_enable = 0;
  OptionalStringValue proxy_server;
  OptionalStringValue proxy_override;
  OptionalStringValue auto_config_url;
  OptionalDwordValue auto_detect;
};

bool ReadBackupProxyState(HKEY backup, ProxyStateSnapshot* state) {
  return ReadDword(backup, L"OriginalProxyEnable", &state->proxy_enable) &&
         ReadOptionalString(backup, L"HasProxyServer", L"OriginalProxyServer",
                            &state->proxy_server.present,
                            &state->proxy_server.value) &&
         ReadOptionalString(backup, L"HasProxyOverride",
                            L"OriginalProxyOverride",
                            &state->proxy_override.present,
                            &state->proxy_override.value) &&
         ReadOptionalString(backup, L"HasAutoConfigURL",
                            L"OriginalAutoConfigURL",
                            &state->auto_config_url.present,
                            &state->auto_config_url.value) &&
         ReadDword(backup, L"HasAutoDetect", &state->auto_detect.present) &&
         ReadDword(backup, L"OriginalAutoDetect", &state->auto_detect.value);
}

bool ReadCurrentProxyState(HKEY settings, ProxyStateSnapshot* state) {
  if (!ReadDword(settings, L"ProxyEnable", &state->proxy_enable)) return false;
  state->proxy_server.present = ValueExists(settings, L"ProxyServer") ? 1 : 0;
  if (state->proxy_server.present != 0 &&
      !ReadString(settings, L"ProxyServer", &state->proxy_server.value)) {
    return false;
  }
  state->proxy_override.present =
      ValueExists(settings, L"ProxyOverride") ? 1 : 0;
  if (state->proxy_override.present != 0 &&
      !ReadString(settings, L"ProxyOverride", &state->proxy_override.value)) {
    return false;
  }
  state->auto_config_url.present =
      ValueExists(settings, L"AutoConfigURL") ? 1 : 0;
  if (state->auto_config_url.present != 0 &&
      !ReadString(settings, L"AutoConfigURL",
                  &state->auto_config_url.value)) {
    return false;
  }
  state->auto_detect.present = ValueExists(settings, L"AutoDetect") ? 1 : 0;
  return state->auto_detect.present == 0 ||
         ReadDword(settings, L"AutoDetect", &state->auto_detect.value);
}

bool ProxyStatesEqual(const ProxyStateSnapshot& left,
                      const ProxyStateSnapshot& right) {
  return left.proxy_enable == right.proxy_enable &&
         left.proxy_server.present == right.proxy_server.present &&
         left.proxy_server.value == right.proxy_server.value &&
         left.proxy_override.present == right.proxy_override.present &&
         left.proxy_override.value == right.proxy_override.value &&
         left.auto_config_url.present == right.auto_config_url.present &&
         left.auto_config_url.value == right.auto_config_url.value &&
         left.auto_detect.present == right.auto_detect.present &&
         left.auto_detect.value == right.auto_detect.value;
}

ProxyStateSnapshot OwnedProxyState(const std::wstring& owned_server,
                                   const std::wstring& owned_override) {
  ProxyStateSnapshot owned;
  owned.proxy_enable = 1;
  owned.proxy_server.present = 1;
  owned.proxy_server.value = owned_server;
  owned.proxy_override.present = 1;
  owned.proxy_override.value = owned_override;
  owned.auto_config_url.present = 0;
  owned.auto_config_url.value.clear();
  owned.auto_detect.present = 1;
  owned.auto_detect.value = 0;
  return owned;
}

std::vector<ProxyStateSnapshot> ActivationPrefixes(
    const ProxyStateSnapshot& original, const ProxyStateSnapshot& owned) {
  std::vector<ProxyStateSnapshot> states = {original};
  ProxyStateSnapshot state = original;
  state.proxy_server = owned.proxy_server;
  states.push_back(state);
  state.proxy_override = owned.proxy_override;
  states.push_back(state);
  state.auto_detect = owned.auto_detect;
  states.push_back(state);
  state.auto_config_url = owned.auto_config_url;
  states.push_back(state);
  state.proxy_enable = owned.proxy_enable;
  states.push_back(state);
  return states;
}

bool IsActivationPrefix(const ProxyStateSnapshot& current,
                        const ProxyStateSnapshot& original,
                        const ProxyStateSnapshot& owned) {
  const auto states = ActivationPrefixes(original, owned);
  for (const auto& state : states) {
    if (ProxyStatesEqual(current, state)) return true;
  }
  return false;
}

bool IsFullRestorePrefix(const ProxyStateSnapshot& current,
                         const ProxyStateSnapshot& original,
                         const ProxyStateSnapshot& owned) {
  for (const auto& activation : ActivationPrefixes(original, owned)) {
    ProxyStateSnapshot state = activation;
    if (ProxyStatesEqual(current, state)) return true;
    if (original.proxy_enable == 0) {
      state.proxy_enable = 0;
      if (ProxyStatesEqual(current, state)) return true;
    }
    state.proxy_server = original.proxy_server;
    if (ProxyStatesEqual(current, state)) return true;
    state.proxy_override = original.proxy_override;
    if (ProxyStatesEqual(current, state)) return true;
    state.auto_config_url = original.auto_config_url;
    if (ProxyStatesEqual(current, state)) return true;
    state.auto_detect = original.auto_detect;
    if (ProxyStatesEqual(current, state)) return true;
    if (original.proxy_enable != 0) {
      state.proxy_enable = original.proxy_enable;
      if (ProxyStatesEqual(current, state)) return true;
    }
  }
  return false;
}

bool IsEndpointRestorePrefix(const ProxyStateSnapshot& current,
                             const ProxyStateSnapshot& original,
                             const ProxyStateSnapshot& owned) {
  const bool owned_server =
      current.proxy_server.present == owned.proxy_server.present &&
      current.proxy_server.value == owned.proxy_server.value;
  const bool original_server =
      current.proxy_server.present == original.proxy_server.present &&
      current.proxy_server.value == original.proxy_server.value;
  if (original.proxy_enable == 0) {
    return (owned_server &&
            (current.proxy_enable == owned.proxy_enable ||
             current.proxy_enable == 0)) ||
           (original_server && current.proxy_enable == 0);
  }
  return (owned_server || original_server) &&
         current.proxy_enable == original.proxy_enable;
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

bool RemoveRecoveryRunOnce() {
  HKEY run_once = nullptr;
  const LSTATUS open_status = RegOpenKeyExW(
      HKEY_CURRENT_USER, kRunOncePath, 0, KEY_SET_VALUE, &run_once);
  if (open_status == ERROR_FILE_NOT_FOUND) return true;
  if (open_status != ERROR_SUCCESS) return false;
  const LSTATUS delete_status =
      RegDeleteValueW(run_once, kRecoveryRunOnceName);
  RegCloseKey(run_once);
  return delete_status == ERROR_SUCCESS ||
         delete_status == ERROR_FILE_NOT_FOUND;
}

bool RemoveRecoveryArtifacts() {
  const LSTATUS backup_status =
      RegDeleteTreeW(HKEY_CURRENT_USER, kBackupPath);
  const bool backup_removed = backup_status == ERROR_SUCCESS ||
                               backup_status == ERROR_FILE_NOT_FOUND;
  return backup_removed && RemoveRecoveryRunOnce();
}

std::wstring JoinPath(const std::wstring& directory,
                      const wchar_t* child) {
  if (directory.empty()) return std::wstring();
  const wchar_t tail = directory.back();
  return directory + (tail == L'\\' || tail == L'/' ? L"" : L"\\") +
         child;
}

bool EnsureDirectory(const std::wstring& path) {
  return CreateDirectoryW(path.c_str(), nullptr) != FALSE ||
         GetLastError() == ERROR_ALREADY_EXISTS;
}

std::wstring ProxyTransactionLockPath() {
  const DWORD required =
      GetEnvironmentVariableW(L"LOCALAPPDATA", nullptr, 0);
  if (required == 0) return std::wstring();
  std::vector<wchar_t> local_app_data(required, L'\0');
  const DWORD length = GetEnvironmentVariableW(
      L"LOCALAPPDATA", local_app_data.data(),
      static_cast<DWORD>(local_app_data.size()));
  if (length == 0 ||
      length >= static_cast<DWORD>(local_app_data.size())) {
    return std::wstring();
  }

  const std::wstring app_directory =
      JoinPath(std::wstring(local_app_data.data(), length), L"SSRVPN");
  const std::wstring runtime_directory = JoinPath(app_directory, L"runtime");
  if (!EnsureDirectory(app_directory) || !EnsureDirectory(runtime_directory)) {
    return std::wstring();
  }
  return JoinPath(runtime_directory, kProxyTransactionLockFile);
}

bool IsNativeRecoveryJournalNonReplayable() noexcept {
  HKEY backup = nullptr;
  const LSTATUS open_status =
      RegOpenKeyExW(HKEY_CURRENT_USER, kBackupPath, 0, KEY_QUERY_VALUE, &backup);
  if (open_status == ERROR_FILE_NOT_FOUND) return true;
  if (open_status != ERROR_SUCCESS) return false;

  DWORD valid = 0;
  const bool valid_read = ReadDword(backup, L"Valid", &valid);
  if (!valid_read || valid != 1) {
    RegCloseKey(backup);
    return valid_read && valid == 0;
  }

  DWORD restore_in_progress = 0;
  DWORD activation_in_progress = 0;
  DWORD endpoint_restore_in_progress = 0;
  const bool flags_read =
      ReadDword(backup, L"RestoreInProgress", &restore_in_progress) &&
      ReadDword(backup, L"ActivationInProgress", &activation_in_progress) &&
      ReadDword(backup, L"EndpointRestoreInProgress",
                &endpoint_restore_in_progress);
  RegCloseKey(backup);
  return flags_read && restore_in_progress == 0 &&
         activation_in_progress == 0 && endpoint_restore_in_progress == 0;
}

}  // namespace

WindowsProxyTransactionLock::WindowsProxyTransactionLock() noexcept {
  const std::wstring lock_path = ProxyTransactionLockPath();
  if (lock_path.empty()) return;
  HANDLE file = CreateFileW(
      lock_path.c_str(), GENERIC_READ | GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;

  OVERLAPPED overlapped = {};
  if (!LockFileEx(file, LOCKFILE_EXCLUSIVE_LOCK, 0, MAXDWORD, MAXDWORD,
                  &overlapped)) {
    CloseHandle(file);
    return;
  }
  file_handle_ = file;
}

WindowsProxyTransactionLock::~WindowsProxyTransactionLock() {
  if (file_handle_ == nullptr) return;
  HANDLE file = file_handle_;
  OVERLAPPED overlapped = {};
  UnlockFileEx(file, 0, MAXDWORD, MAXDWORD, &overlapped);
  CloseHandle(file);
}

bool WindowsProxyTransactionLock::acquired() const noexcept {
  return file_handle_ != nullptr;
}

bool IsOwnedWindowsProxyEndpointSafeToStopUnlocked() noexcept {
  HKEY settings = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kInternetSettingsPath, 0,
                    KEY_QUERY_VALUE, &settings) != ERROR_SUCCESS) {
    return false;
  }

  DWORD proxy_enable = 0;
  DWORD proxy_enable_type = 0;
  DWORD proxy_enable_size = sizeof(proxy_enable);
  const LSTATUS proxy_enable_status = RegQueryValueExW(
      settings, L"ProxyEnable", nullptr, &proxy_enable_type,
      reinterpret_cast<BYTE*>(&proxy_enable), &proxy_enable_size);
  if (proxy_enable_status == ERROR_FILE_NOT_FOUND ||
      (proxy_enable_status == ERROR_SUCCESS &&
       proxy_enable_type == REG_DWORD &&
       proxy_enable_size == sizeof(proxy_enable) && proxy_enable == 0)) {
    RegCloseKey(settings);
    return true;
  }
  if (proxy_enable_status != ERROR_SUCCESS ||
      proxy_enable_type != REG_DWORD ||
      proxy_enable_size != sizeof(proxy_enable)) {
    RegCloseKey(settings);
    return false;
  }

  std::wstring proxy_server;
  if (!ReadString(settings, L"ProxyServer", &proxy_server)) {
    RegCloseKey(settings);
    return false;
  }
  RegCloseKey(settings);

  HKEY backup = nullptr;
  const LSTATUS backup_status =
      RegOpenKeyExW(HKEY_CURRENT_USER, kBackupPath, 0, KEY_READ, &backup);
  if (backup_status == ERROR_FILE_NOT_FOUND) {
    return !IsOwnedProxyServer(proxy_server);
  }
  if (backup_status != ERROR_SUCCESS) {
    return false;
  }
  std::wstring owned_server;
  const bool safe = ReadString(backup, L"OwnedProxyServer", &owned_server) &&
                    IsOwnedProxyServer(owned_server) &&
                    proxy_server != owned_server;
  RegCloseKey(backup);
  return safe;
}

bool IsOwnedWindowsProxySafeToStopUnlocked() noexcept {
  return IsNativeRecoveryJournalNonReplayable() &&
         IsOwnedWindowsProxyEndpointSafeToStopUnlocked();
}

bool RearmWindowsProxyRecoveryRunOnce() noexcept {
  std::wstring executable(32768, L'\0');
  const DWORD length = GetModuleFileNameW(
      nullptr, executable.data(), static_cast<DWORD>(executable.size()));
  if (length == 0 || length >= executable.size()) return false;
  executable.resize(length);

  return RearmWindowsProxyRecoveryRunOnce(executable.c_str());
}

bool RearmWindowsProxyRecoveryRunOnce(
    const wchar_t* recovery_executable) noexcept {
  if (recovery_executable == nullptr || recovery_executable[0] == L'\0') {
    return false;
  }

  const std::wstring command =
      L"\"" + std::wstring(recovery_executable) +
      L"\" --recover-proxy-only";
  HKEY run_once = nullptr;
  const LSTATUS create_status = RegCreateKeyExW(
      HKEY_CURRENT_USER, kRunOncePath, 0, nullptr, 0, KEY_SET_VALUE, nullptr,
      &run_once, nullptr);
  if (create_status != ERROR_SUCCESS) return false;
  const DWORD command_size =
      static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t));
  const LSTATUS set_status = RegSetValueExW(
      run_once, kRecoveryRunOnceName, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(command.c_str()), command_size);
  RegCloseKey(run_once);
  return set_status == ERROR_SUCCESS;
}

bool RestoreOwnedWindowsProxyUnlocked() noexcept {
  HKEY backup = nullptr;
  const LSTATUS backup_open_status =
      RegOpenKeyExW(HKEY_CURRENT_USER, kBackupPath, 0,
                    KEY_READ | KEY_SET_VALUE, &backup);
  if (backup_open_status != ERROR_SUCCESS) {
    if (backup_open_status == ERROR_FILE_NOT_FOUND &&
        IsOwnedWindowsProxySafeToStopUnlocked()) {
      return RemoveRecoveryRunOnce();
    }
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
    if (disabled) {
      NotifyWinInet();
      return false;
    }
    if (IsOwnedWindowsProxyEndpointSafeToStopUnlocked()) {
      return RemoveRecoveryArtifacts();
    }
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

  ProxyStateSnapshot original;
  const bool snapshot_valid = ReadBackupProxyState(backup, &original);
  ProxyStateSnapshot current;
  const bool current_valid = ReadCurrentProxyState(settings, &current);
  const ProxyStateSnapshot owned_state =
      OwnedProxyState(owned_server, owned_override);
  const bool activation_prefix = snapshot_valid && current_valid &&
                                 activation_in_progress == 1 &&
                                 restore_in_progress == 0 &&
                                 endpoint_restore_in_progress == 0 &&
                                 IsActivationPrefix(current, original,
                                                    owned_state);
  const bool full_restore_prefix = snapshot_valid && current_valid &&
                                   restore_in_progress == 1 &&
                                   endpoint_restore_in_progress == 0 &&
                                   IsFullRestorePrefix(current, original,
                                                       owned_state);
  const bool endpoint_restore_prefix =
      snapshot_valid && current_valid && restore_in_progress == 0 &&
      endpoint_restore_in_progress == 1 &&
      IsEndpointRestorePrefix(current, original, owned_state);
  const bool restore_full = owned || activation_prefix || full_restore_prefix;
  const bool restore_endpoint =
      (!restore_full && endpoint_owned) || endpoint_restore_prefix;
  if (restore_endpoint) {
    bool endpoint_restored =
        snapshot_valid &&
        (endpoint_restore_in_progress == 1 ||
         SetDword(backup, L"EndpointRestoreInProgress", 1)) &&
        (original.proxy_enable != 0 ||
         SetDword(settings, L"ProxyEnable", 0)) &&
        RestorePreparedString(settings, original.proxy_server.present,
                              original.proxy_server.value, L"ProxyServer") &&
        (original.proxy_enable == 0 ||
         SetDword(settings, L"ProxyEnable", original.proxy_enable));
    const bool valid_terminal =
        endpoint_restored && SetDword(backup, L"Valid", 0);
    const bool restore_terminal =
        endpoint_restored && SetDword(backup, L"RestoreInProgress", 0);
    const bool endpoint_terminal = endpoint_restored &&
                                   SetDword(backup,
                                            L"EndpointRestoreInProgress", 0);
    const bool activation_terminal =
        endpoint_restored && SetDword(backup, L"ActivationInProgress", 0);
    const bool journal_terminal =
        valid_terminal ||
        (restore_terminal && endpoint_terminal && activation_terminal);
    const bool endpoint_disabled =
        !endpoint_restored && DisableOwnedProxyEndpoint(settings, owned_server);
    RegCloseKey(settings);
    RegCloseKey(backup);
    if (!endpoint_restored) {
      if (endpoint_disabled) NotifyWinInet();
      return false;
    }
    const bool artifacts_removed = RemoveRecoveryArtifacts();
    NotifyWinInet();
    return journal_terminal || artifacts_removed;
  }
  if (!restore_full) {
    RegCloseKey(settings);
    RegCloseKey(backup);
    return RemoveRecoveryArtifacts();
  }

  bool settings_restored =
      snapshot_valid &&
      (restore_in_progress == 1 ||
       SetDword(backup, L"RestoreInProgress", 1));
  if (settings_restored) {
    settings_restored =
        (original.proxy_enable != 0 ||
         SetDword(settings, L"ProxyEnable", 0)) &&
        RestorePreparedString(settings, original.proxy_server.present,
                              original.proxy_server.value, L"ProxyServer") &&
        RestorePreparedString(settings, original.proxy_override.present,
                              original.proxy_override.value,
                              L"ProxyOverride") &&
        RestorePreparedString(settings, original.auto_config_url.present,
                              original.auto_config_url.value,
                              L"AutoConfigURL") &&
        (original.auto_detect.present != 0
             ? SetDword(settings, L"AutoDetect", original.auto_detect.value)
             : DeleteValueIfPresent(settings, L"AutoDetect")) &&
        (original.proxy_enable == 0 ||
         SetDword(settings, L"ProxyEnable", original.proxy_enable));
  }
  const bool valid_terminal =
      settings_restored && SetDword(backup, L"Valid", 0);
  const bool restore_terminal =
      settings_restored && SetDword(backup, L"RestoreInProgress", 0);
  const bool endpoint_terminal = settings_restored &&
                                 SetDword(backup,
                                          L"EndpointRestoreInProgress", 0);
  const bool activation_terminal =
      settings_restored && SetDword(backup, L"ActivationInProgress", 0);
  const bool journal_terminal =
      valid_terminal ||
      (restore_terminal && endpoint_terminal && activation_terminal);

  const bool endpoint_disabled =
      !settings_restored && DisableOwnedProxyEndpoint(settings, owned_server);
  RegCloseKey(settings);
  RegCloseKey(backup);
  if (!settings_restored) {
    if (endpoint_disabled) NotifyWinInet();
    return false;
  }
  const bool artifacts_removed = RemoveRecoveryArtifacts();
  NotifyWinInet();
  return journal_terminal || artifacts_removed;
}

bool RestoreOwnedWindowsProxy(
    const WindowsProxyTransactionLock& transaction_lock) noexcept {
  return transaction_lock.acquired() && RestoreOwnedWindowsProxyUnlocked();
}

bool RestoreOwnedWindowsProxy() noexcept {
  WindowsProxyTransactionLock transaction_lock;
  return RestoreOwnedWindowsProxy(transaction_lock);
}

bool IsOwnedWindowsProxySafeToStop(
    const WindowsProxyTransactionLock& transaction_lock) noexcept {
  return transaction_lock.acquired() &&
         IsOwnedWindowsProxySafeToStopUnlocked();
}

bool IsOwnedWindowsProxySafeToStop() noexcept {
  WindowsProxyTransactionLock transaction_lock;
  return IsOwnedWindowsProxySafeToStop(transaction_lock);
}

bool RestoreOrConfirmOwnedWindowsProxySafeToStop() noexcept {
  WindowsProxyTransactionLock transaction_lock;
  return RestoreOwnedWindowsProxy(transaction_lock) ||
         IsOwnedWindowsProxySafeToStop(transaction_lock);
}
