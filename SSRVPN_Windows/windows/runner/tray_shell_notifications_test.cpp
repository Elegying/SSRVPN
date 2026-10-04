#include "tray_shell_notifications.h"
#include <sddl.h>
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstdint>
#include <iostream>
#include <string>

namespace {
int received = 0;
LRESULT CALLBACK TestWindowProc(HWND window, UINT message, WPARAM wparam,
                               LPARAM lparam) {
  if (message == ::RegisterWindowMessageW(L"TaskbarCreated")) {
    ++received;
    return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

void SendFromLowerIntegrity(HWND window, bool allowed) {
  HANDLE original = nullptr;
  HANDLE restricted = nullptr;
  assert(::OpenProcessToken(::GetCurrentProcess(), TOKEN_ALL_ACCESS, &original));
  assert(::CreateRestrictedToken(original, DISABLE_MAX_PRIVILEGE, 0, nullptr,
                                  0, nullptr, 0, nullptr, &restricted));
  PSID low_sid = nullptr;
  assert(::ConvertStringSidToSidW(L"S-1-16-4096", &low_sid));
  TOKEN_MANDATORY_LABEL label = {};
  label.Label.Sid = low_sid;
  label.Label.Attributes = SE_GROUP_INTEGRITY;
  assert(::SetTokenInformation(restricted, TokenIntegrityLevel, &label,
                               static_cast<DWORD>(sizeof(label)) + ::GetLengthSid(low_sid)));
  ::LocalFree(low_sid);
  wchar_t executable[32768] = {};
  assert(::GetModuleFileNameW(nullptr, executable, 32768) != 0);
  std::wstring command = L"\"" + std::wstring(executable) + L"\" --send " +
      std::to_wstring(reinterpret_cast<uintptr_t>(window)) +
      (allowed ? L" yes" : L" no");
  STARTUPINFOW startup = {};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION child = {};
  const BOOL started = ::CreateProcessAsUserW(restricted, executable,
      command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr,
      nullptr, &startup, &child);
  const DWORD error = started ? ERROR_SUCCESS : ::GetLastError();
  ::CloseHandle(original);
  ::CloseHandle(restricted);
  if (!started) std::cerr << "Restricted child launch failed: " << error << '\n';
  assert(started);
  assert(::WaitForSingleObject(child.hProcess, 10000) == WAIT_OBJECT_0);
  DWORD code = 1;
  assert(::GetExitCodeProcess(child.hProcess, &code));
  ::CloseHandle(child.hThread);
  ::CloseHandle(child.hProcess);
  assert(code == 0);
  MSG message = {};
  while (::PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
    ::TranslateMessage(&message);
    ::DispatchMessageW(&message);
  }
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc == 4 && std::wstring(argv[1]) == L"--send") {
    const HWND target = reinterpret_cast<HWND>(std::stoull(argv[2]));
    const bool allowed = std::wstring(argv[3]) == L"yes";
    const UINT taskbar = ::RegisterWindowMessageW(L"TaskbarCreated");
    ::SetLastError(ERROR_SUCCESS);
    const bool posted = ::PostMessageW(target, taskbar, 0, 0) != FALSE;
    if (posted != allowed || (!posted && ::GetLastError() != ERROR_ACCESS_DENIED)) return 1;
    const UINT unrelated = ::RegisterWindowMessageW(L"SSRVPN_Test_Unrelated");
    ::SetLastError(ERROR_SUCCESS);
    if (::PostMessageW(target, unrelated, 0, 0) || ::GetLastError() != ERROR_ACCESS_DENIED) return 2;
    return 0;
  }
  WNDCLASSW window_class = {};
  window_class.lpfnWndProc = TestWindowProc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = L"SSRVPN_Tray_Filter_Test";
  assert(::RegisterClassW(&window_class));
  const HWND window = ::CreateWindowW(window_class.lpszClassName, L"", 0,
      0, 0, 0, 0, nullptr, nullptr, window_class.hInstance, nullptr);
  assert(window != nullptr);
  SendFromLowerIntegrity(window, false);
  assert(received == 0);
  assert(EnableTaskbarRecreationNotifications(window));
  SendFromLowerIntegrity(window, true);
  assert(received == 1);
  assert(::DestroyWindow(window));
  ::UnregisterClassW(window_class.lpszClassName, window_class.hInstance);
  std::cout << "Tray recreation notification crosses UIPI; unrelated messages remain blocked.\n";
}
