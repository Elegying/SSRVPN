#include "system_proxy_snapshot.h"

#include <cwchar>
#include <thread>

namespace {
bool PutDword(HKEY key, const wchar_t* name, DWORD value) {
  return RegSetValueExW(key, name, 0, REG_DWORD,
      reinterpret_cast<const BYTE*>(&value), sizeof(value)) == ERROR_SUCCESS;
}
bool PutText(HKEY key, const wchar_t* name, const wchar_t* text) {
  return RegSetValueExW(key, name, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(text),
      static_cast<DWORD>((std::wcslen(text) + 1) * sizeof(wchar_t))) == ERROR_SUCCESS;
}

bool ExerciseSnapshot(HKEY root, HKEY settings, HKEY policy) {
  const auto name = L"Local\\SSRVPNProxyReadTest-" +
      std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64());
  auto read = [&] (bool guardian = false) {
    return ReadWindowsProxySnapshotForTesting(root, settings, guardian, name.c_str());
  };
  if (!PutDword(settings, L"TestConnectionFlags", 9) ||
      !PutText(settings, L"ProxyServer", L"代理.example:8080")) return false;
  auto result = read();
  if (result.status != ProxySnapshotStatus::ok ||
      result.snapshot.has_proxy_enable || result.snapshot.proxy_enable != 0 ||
      !result.snapshot.has_proxy_server ||
      result.snapshot.proxy_server != L"代理.example:8080" ||
      result.snapshot.connection_flags != 9) return false;
  if (read(true).status != ProxySnapshotStatus::guardian_missing) return false;
  HANDLE guardian = CreateMutexW(nullptr, FALSE, name.c_str());
  if (guardian == nullptr) return false;
  bool ok = read(true).status == ProxySnapshotStatus::guardian_missing;
  HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  HANDLE finish = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (ready == nullptr || finish == nullptr) {
    if (ready != nullptr) CloseHandle(ready);
    if (finish != nullptr) CloseHandle(finish);
    CloseHandle(guardian);
    return false;
  }
  std::thread owner([&] {
    WaitForSingleObject(guardian, INFINITE);
    SetEvent(ready);
    WaitForSingleObject(finish, INFINITE);
    ReleaseMutex(guardian);
  });
  WaitForSingleObject(ready, INFINITE);
  ok = ok && read(true).status == ProxySnapshotStatus::ok;
  SetEvent(finish);
  owner.join();
  std::thread abandoned([&] { WaitForSingleObject(guardian, INFINITE); });
  abandoned.join();
  ok = ok && read(true).status == ProxySnapshotStatus::guardian_missing;
  CloseHandle(ready); CloseHandle(finish); CloseHandle(guardian);
  if (!ok) return false;
  if (!PutDword(policy, L"ProxySettingsPerUser", 0) ||
      read().status != ProxySnapshotStatus::policy_denied) return false;
  if (!PutText(policy, L"ProxySettingsPerUser", L"1") ||
      read().status != ProxySnapshotStatus::policy_denied) return false;
  if (!PutDword(policy, L"ProxySettingsPerUser", 1) ||
      read().status != ProxySnapshotStatus::ok) return false;
  if (!PutText(settings, L"ProxyEnable", L"1") ||
      read().status != ProxySnapshotStatus::unavailable) return false;
  if (!PutDword(settings, L"ProxyEnable", 2) ||
      read().status != ProxySnapshotStatus::unavailable) return false;
  if (!PutDword(settings, L"ProxyEnable", 1) ||
      read().status != ProxySnapshotStatus::ok) return false;
  if (!PutDword(settings, L"TestConnectionFlags", 16) ||
      read().status != ProxySnapshotStatus::unavailable ||
      !PutDword(settings, L"TestConnectionFlags", 3)) return false;
  const wchar_t embedded[] = {L'a', L'\0', L'b', L'\0'};
  if (RegSetValueExW(settings, L"ProxyServer", 0, REG_SZ,
      reinterpret_cast<const BYTE*>(embedded), static_cast<DWORD>(sizeof(embedded))) != ERROR_SUCCESS ||
      read().status != ProxySnapshotStatus::unavailable) return false;
  return ReadWindowsProxySnapshotForTesting(root, nullptr, false, name.c_str()).status
      == ProxySnapshotStatus::unavailable;
}
}  // namespace

bool RunWindowsProxySnapshotTests() {
  const auto path = L"SSRVPNNativeSnapshotTests-" +
      std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64());
  HKEY root = nullptr, settings = nullptr, policy = nullptr;
  DWORD disposition = 0;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, path.c_str(), 0, nullptr,
      REG_OPTION_VOLATILE, KEY_ALL_ACCESS, nullptr, &root, &disposition) != ERROR_SUCCESS)
    return false;
  if (disposition != REG_CREATED_NEW_KEY) { RegCloseKey(root); return false; }
  const bool opened = RegCreateKeyExW(root, L"Settings", 0, nullptr,
      REG_OPTION_VOLATILE, KEY_ALL_ACCESS, nullptr, &settings, nullptr) == ERROR_SUCCESS &&
      RegCreateKeyExW(root,
          L"SOFTWARE\\Policies\\Microsoft\\Windows\\CurrentVersion\\Internet Settings",
          0, nullptr, REG_OPTION_VOLATILE, KEY_ALL_ACCESS, nullptr,
          &policy, nullptr) == ERROR_SUCCESS;
  const bool ok = opened && ExerciseSnapshot(root, settings, policy);
  if (settings != nullptr) RegCloseKey(settings);
  if (policy != nullptr) RegCloseKey(policy);
  RegCloseKey(root);
  RegDeleteTreeW(HKEY_CURRENT_USER, path.c_str());
  return ok;
}
