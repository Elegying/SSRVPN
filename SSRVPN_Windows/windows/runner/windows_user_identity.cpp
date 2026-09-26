#include "windows_user_identity.h"

#include <windows.h>
#include <sddl.h>

#include <vector>

namespace windows_user_identity {

std::wstring QueryCurrentUserSid() {
  return QueryProcessUserSid(::GetCurrentProcess());
}

std::wstring QueryProcessUserSid(HANDLE process) {
  HANDLE token = nullptr;
  if (!::OpenProcessToken(process, TOKEN_QUERY, &token)) {
    return std::wstring();
  }
  DWORD bytes = 0;
  ::GetTokenInformation(token, TokenUser, nullptr, 0, &bytes);
  if (bytes == 0 || ::GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
    ::CloseHandle(token);
    return std::wstring();
  }
  std::vector<unsigned char> token_user_storage(bytes);
  if (!::GetTokenInformation(token, TokenUser, token_user_storage.data(),
                             bytes, &bytes)) {
    ::CloseHandle(token);
    return std::wstring();
  }
  ::CloseHandle(token);

  const auto* token_user =
      reinterpret_cast<const TOKEN_USER*>(token_user_storage.data());
  wchar_t* sid_text = nullptr;
  if (!::ConvertSidToStringSidW(token_user->User.Sid, &sid_text) ||
      sid_text == nullptr) {
    return std::wstring();
  }
  const std::wstring result(sid_text);
  ::LocalFree(sid_text);
  return result;
}

bool SameUser(const std::wstring& current_sid, const std::wstring& other_sid) {
  return !current_sid.empty() && !other_sid.empty() && current_sid == other_sid;
}

bool IsCurrentUserInteractiveUser() {
  DWORD shell_pid = 0;
  const HWND shell_window = ::GetShellWindow();
  if (shell_window == nullptr ||
      ::GetWindowThreadProcessId(shell_window, &shell_pid) == 0 || shell_pid == 0) {
    return false;
  }
  DWORD shell_session = 0;
  DWORD current_session = 0;
  if (!::ProcessIdToSessionId(shell_pid, &shell_session) ||
      !::ProcessIdToSessionId(::GetCurrentProcessId(), &current_session) ||
      shell_session != current_session) return false;
  HANDLE shell = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, shell_pid);
  if (shell == nullptr) return false;
  std::vector<wchar_t> image(32768);
  DWORD image_size = static_cast<DWORD>(image.size());
  std::vector<wchar_t> windows(32768);
  const UINT size = ::GetWindowsDirectoryW(windows.data(), static_cast<UINT>(windows.size()));
  const bool valid_image = size > 0 && size < windows.size() &&
      ::QueryFullProcessImageNameW(shell, 0, image.data(), &image_size) &&
      ::_wcsicmp(image.data(), (std::wstring(windows.data(), size) + L"\\explorer.exe").c_str()) == 0;
  const std::wstring shell_sid = valid_image ? QueryProcessUserSid(shell) : L"";
  ::CloseHandle(shell);
  const std::wstring current_sid = QueryCurrentUserSid();
  return SameUser(current_sid, shell_sid);
}

}  // namespace windows_user_identity
