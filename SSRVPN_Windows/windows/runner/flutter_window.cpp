#include "flutter_window.h"

#include <flutter/plugin_registry.h>
#include <screen_retriever_windows/screen_retriever_windows_plugin_c_api.h>
#include <system_tray/system_tray_plugin.h>
#include <window_manager/window_manager_plugin.h>

#include <optional>
#include <string>

#include "startup_diagnostics.h"

namespace {

bool HasCommandLineFlag(const wchar_t* flag) {
  if (flag == nullptr) {
    return false;
  }
  const wchar_t* command_line = ::GetCommandLineW();
  if (command_line == nullptr) {
    return false;
  }
  return std::wstring(command_line).find(flag) != std::wstring::npos;
}

// Helper functions for safe plugin registration
// Note: Global exception handlers in startup_diagnostics.cpp will catch any crashes
static void SafeRegisterScreenRetriever(flutter::PluginRegistry* registry) {
  ScreenRetrieverWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ScreenRetrieverWindowsPluginCApi"));
}

static void SafeRegisterSystemTray(flutter::PluginRegistry* registry) {
  SystemTrayPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("SystemTrayPlugin"));
}

static void SafeRegisterWindowManager(flutter::PluginRegistry* registry) {
  WindowManagerPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("WindowManagerPlugin"));
}

void RegisterScreenRetriever(flutter::PluginRegistry* registry) {
  SafeRegisterScreenRetriever(registry);
}

void RegisterSystemTray(flutter::PluginRegistry* registry) {
  SafeRegisterSystemTray(registry);
}

void RegisterWindowManager(flutter::PluginRegistry* registry) {
  SafeRegisterWindowManager(registry);
}

void RegisterPluginsSafely(flutter::PluginRegistry* registry) {
  const bool safe_mode = HasCommandLineFlag(L"--safe-mode");
  const bool disable_tray =
      safe_mode || HasCommandLineFlag(L"--disable-tray");

  startup_diagnostics::Log(L"plugin registration start");

  if (safe_mode) {
    startup_diagnostics::Log(
        L"plugin registration skipped by --safe-mode");
    startup_diagnostics::Log(L"plugin registration end");
    return;
  }

  startup_diagnostics::Log(L"register screen_retriever start");
  RegisterScreenRetriever(registry);
  startup_diagnostics::Log(L"register screen_retriever end");

  if (disable_tray) {
    startup_diagnostics::Log(L"register system_tray skipped");
  } else {
    startup_diagnostics::Log(L"register system_tray start");
    RegisterSystemTray(registry);
    startup_diagnostics::Log(L"register system_tray end");
  }

  startup_diagnostics::Log(L"register window_manager start");
  RegisterWindowManager(registry);
  startup_diagnostics::Log(L"register window_manager end");

  startup_diagnostics::Log(L"plugin registration end");
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  startup_diagnostics::Log(L"Flutter engine create start");
  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    startup_diagnostics::Log(L"Flutter engine create failed");
    return false;
  }
  startup_diagnostics::Log(L"Flutter engine create end");

  RegisterPluginsSafely(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
