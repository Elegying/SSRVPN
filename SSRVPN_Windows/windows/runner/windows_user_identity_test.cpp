#include "windows_user_identity.h"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <iostream>

int main() {
  using namespace windows_user_identity;
  const auto current = QueryCurrentUserSid();
  assert(!current.empty());
  assert(SameUser(current, QueryProcessUserSid(::GetCurrentProcess())));
  assert(QueryProcessUserSid(nullptr).empty());
  assert(SameUser(current, QueryProcessUserSid(INVALID_HANDLE_VALUE))); // current-process pseudo handle
  assert(!SameUser(L"", current));
  assert(!SameUser(current, L""));
  assert(!SameUser(L"", L""));
  assert(!SameUser(L"S-1-5-21-1-2-3-1001", L"S-1-5-21-1-2-3-1002"));
  assert(SameUser(L"S-1-5-21-1-2-3-1001", L"S-1-5-21-1-2-3-1001"));
  // The test does not require Explorer on a headless runner. Unknown identity
  // must be rejected, while a real shell is compared using its actual token.
  DWORD shell_pid = 0;
  const HWND shell = ::GetShellWindow();
  if (shell == nullptr) {
    assert(!IsCurrentUserInteractiveUser());
  } else {
    ::GetWindowThreadProcessId(shell, &shell_pid);
    HANDLE process = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, shell_pid);
    if (process != nullptr) {
      if (!SameUser(current, QueryProcessUserSid(process)))
        assert(!IsCurrentUserInteractiveUser());
      ::CloseHandle(process);
    }
  }
  std::cout << "User token identity: current, unknown and cross-account checks passed.\n";
}
