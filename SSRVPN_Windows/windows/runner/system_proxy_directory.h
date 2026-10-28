#ifndef SSRVPN_SYSTEM_PROXY_DIRECTORY_H_
#define SSRVPN_SYSTEM_PROXY_DIRECTORY_H_

#include <windows.h>
#include <shlobj.h>
#include <string>
#include <vector>

// Native recovery and Dart must agree on the directory. Never create recovery
// files in an arbitrary location supplied through the process environment.
inline std::wstring TrustedProxyLocalAppData() {
  PWSTR folder = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &folder)))
    return {};
  std::wstring trusted(folder);
  CoTaskMemFree(folder);
  const DWORD size = GetEnvironmentVariableW(L"LOCALAPPDATA", nullptr, 0);
  if (size == 0) return {};
  std::vector<wchar_t> buffer(size);
  const DWORD length = GetEnvironmentVariableW(L"LOCALAPPDATA", buffer.data(), size);
  if (length == 0 || length >= size) return {};
  std::wstring configured(buffer.data(), length);
  while (!configured.empty() &&
         (configured.back() == L'\\' || configured.back() == L'/'))
    configured.pop_back();
  if (_wcsicmp(configured.c_str(), trusted.c_str()) != 0) return {};
  return trusted;
}

#endif
