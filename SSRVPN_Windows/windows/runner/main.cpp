#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "startup_diagnostics.h"
#include "system_proxy_recovery.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  startup_diagnostics::Initialize();
  startup_diagnostics::Log(L"process start");
  startup_diagnostics::Log(std::wstring(L"command line: ") +
                           ::GetCommandLineW());
  startup_diagnostics::Log(std::wstring(L"executable path: ") +
                           startup_diagnostics::GetExecutablePath());

  HANDLE instance_mutex =
      ::CreateMutexW(nullptr, TRUE, L"Local\\SSRVPN_Windows_SingleInstance");
  bool owns_instance_mutex =
      instance_mutex != nullptr && ::GetLastError() != ERROR_ALREADY_EXISTS;
  if (instance_mutex != nullptr && !owns_instance_mutex) {
    startup_diagnostics::Log(L"existing instance detected");
    HWND existing_window =
        ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"SSRVPN");
    if (existing_window == nullptr) {
      existing_window =
          ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"ssrvpn_windows");
    }
    if (existing_window != nullptr) {
      if (!::IsHungAppWindow(existing_window)) {
        ::ShowWindow(existing_window, SW_SHOW);
        ::ShowWindow(existing_window, SW_RESTORE);
        ::SetForegroundWindow(existing_window);
        ::CloseHandle(instance_mutex);
        return ERROR_ALREADY_EXISTS;
      }
      startup_diagnostics::Log(L"existing instance window is hung");
    } else {
      startup_diagnostics::Log(L"existing instance window not found");
    }
    ::CloseHandle(instance_mutex);
    return ERROR_ALREADY_EXISTS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  startup_diagnostics::Log(L"window create start");
  if (!window.Create(L"SSRVPN", origin, size)) {
    startup_diagnostics::Log(L"window create failed");
    startup_diagnostics::WriteDesktopFailureLog(L"window create failed");
    if (owns_instance_mutex) {
      RestoreOwnedWindowsProxy();
    }
    if (instance_mutex != nullptr) {
      ::CloseHandle(instance_mutex);
    }
    return EXIT_FAILURE;
  }
  startup_diagnostics::Log(L"window create end");
  startup_diagnostics::Log(L"window show start");
  window.Show();
  startup_diagnostics::Log(L"window show end");
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }
  if (owns_instance_mutex) {
    RestoreOwnedWindowsProxy();
  }
  startup_diagnostics::Log(L"message loop ended");
  window.Destroy();
  ::CoUninitialize();
  startup_diagnostics::MarkNormalShutdown();
  if (instance_mutex != nullptr && owns_instance_mutex) {
    ::ReleaseMutex(instance_mutex);
    ::CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
