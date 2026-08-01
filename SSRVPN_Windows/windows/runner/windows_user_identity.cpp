#include "windows_user_identity.h"

#include <windows.h>
#include <sddl.h>

#include <vector>

namespace windows_user_identity {

std::wstring QueryCurrentUserSid() {
  HANDLE token = nullptr;
  if (!::OpenProcessToken(::GetCurrentProcess(), TOKEN_QUERY, &token)) {
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

}  // namespace windows_user_identity
