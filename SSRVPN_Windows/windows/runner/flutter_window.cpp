#include "flutter_window.h"

#include <flutter/plugin_registry.h>
#include <flutter/standard_method_codec.h>
#include <screen_retriever_windows/screen_retriever_windows_plugin_c_api.h>
#include <sddl.h>
#include <shellapi.h>
#include <system_tray/system_tray_plugin.h>
#include <window_manager/window_manager_plugin.h>

#include <optional>
#include <string>
#include <vector>

#include "startup_diagnostics.h"
#include "system_proxy_recovery.h"

namespace {

constexpr wchar_t kElevatedTunRelaunchArgument[] =
    L"--ssrvpn-elevated-tun-relaunch";
constexpr wchar_t kElevatedTunUserArgumentPrefix[] =
    L"--ssrvpn-elevated-tun-user=";
constexpr wchar_t kElevatedTunReadyArgumentPrefix[] =
    L"--ssrvpn-elevated-tun-ready=";
constexpr wchar_t kElevatedTunReadyEventPrefix[] =
    L"Local\\SSRVPN_Windows_TunElevationReady_";
constexpr DWORD kElevatedLauncherValidationMilliseconds = 10000;

enum class ProcessElevationState {
  kElevated,
  kLimited,
  kStandard,
  kUnknown,
};

ProcessElevationState QueryProcessElevationState() {
  HANDLE token = nullptr;
  if (!::OpenProcessToken(::GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return ProcessElevationState::kUnknown;
  }

  TOKEN_ELEVATION elevation = {};
  DWORD bytes = 0;
  if (::GetTokenInformation(token, TokenElevation, &elevation,
                            sizeof(elevation), &bytes) &&
      elevation.TokenIsElevated != 0) {
    ::CloseHandle(token);
    return ProcessElevationState::kElevated;
  }

  TOKEN_ELEVATION_TYPE elevation_type = TokenElevationTypeDefault;
  const bool type_read =
      ::GetTokenInformation(token, TokenElevationType, &elevation_type,
                            sizeof(elevation_type), &bytes) != FALSE;
  ::CloseHandle(token);
  if (!type_read) {
    return ProcessElevationState::kUnknown;
  }
  return elevation_type == TokenElevationTypeLimited
             ? ProcessElevationState::kLimited
             : ProcessElevationState::kStandard;
}

std::string ElevationStateName(ProcessElevationState state) {
  switch (state) {
    case ProcessElevationState::kElevated:
      return "elevated";
    case ProcessElevationState::kLimited:
      return "limited";
    case ProcessElevationState::kStandard:
      return "standard";
    case ProcessElevationState::kUnknown:
      return "unknown";
  }
  return "unknown";
}

std::wstring GetCurrentExecutablePath() {
  std::vector<wchar_t> buffer(MAX_PATH);
  while (buffer.size() <= 32768) {
    const DWORD length = ::GetModuleFileNameW(
        nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0) {
      return std::wstring();
    }
    if (length < buffer.size() - 1) {
      return std::wstring(buffer.data(), length);
    }
    buffer.resize(buffer.size() * 2);
  }
  return std::wstring();
}

std::wstring ParentDirectory(const std::wstring& path) {
  const size_t slash = path.find_last_of(L"\\/");
  return slash == std::wstring::npos ? std::wstring() : path.substr(0, slash);
}

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

std::string RequestElevatedTunRelaunch() {
  const ProcessElevationState state = QueryProcessElevationState();
  if (state == ProcessElevationState::kElevated) {
    return "alreadyElevated";
  }
  // A limited token proves that this same Windows account has a linked full
  // administrator token. Refuse over-the-shoulder credentials for a different
  // account because the app's API secret is protected with current-user DPAPI.
  if (state == ProcessElevationState::kStandard) {
    return "standardUser";
  }
  if (state != ProcessElevationState::kLimited) {
    return "failed";
  }

  const std::wstring child_path = GetCurrentExecutablePath();
  const std::wstring child_directory = ParentDirectory(child_path);
  const std::wstring launcher_directory = ParentDirectory(child_directory);
  const std::wstring launcher_path =
      launcher_directory.empty()
          ? std::wstring()
          : launcher_directory + L"\\ssrvpn_windows.exe";
  const DWORD launcher_attributes =
      launcher_path.empty()
          ? INVALID_FILE_ATTRIBUTES
          : ::GetFileAttributesW(launcher_path.c_str());
  if (launcher_attributes == INVALID_FILE_ATTRIBUTES ||
      (launcher_attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
    startup_diagnostics::Log(
        L"TUN elevation refused because the canonical launcher is missing");
    return "failed";
  }
  const std::wstring current_user_sid = QueryCurrentUserSid();
  if (current_user_sid.empty()) {
    startup_diagnostics::Log(
        L"TUN elevation refused because the current user SID is unavailable");
    return "failed";
  }
  const std::wstring ready_event_name =
      std::wstring(kElevatedTunReadyEventPrefix) +
      std::to_wstring(::GetCurrentProcessId()) + L"_" +
      std::to_wstring(::GetTickCount64());
  // The medium-integrity account may wait on the event, but only a token with
  // the Administrators SID enabled may acknowledge the handoff. This prevents
  // another ordinary process running as the same user from spoofing success.
  const std::wstring ready_event_sddl =
      L"D:P(A;;0x00100000;;;" + current_user_sid + L")(A;;0x0002;;;BA)";
  PSECURITY_DESCRIPTOR ready_event_security = nullptr;
  if (!::ConvertStringSecurityDescriptorToSecurityDescriptorW(
          ready_event_sddl.c_str(), SDDL_REVISION_1,
          &ready_event_security, nullptr) ||
      ready_event_security == nullptr) {
    startup_diagnostics::Log(
        L"TUN elevation refused because the handoff ACL is unavailable");
    return "failed";
  }
  SECURITY_ATTRIBUTES ready_event_attributes = {};
  ready_event_attributes.nLength = sizeof(ready_event_attributes);
  ready_event_attributes.lpSecurityDescriptor = ready_event_security;
  ready_event_attributes.bInheritHandle = FALSE;
  HANDLE ready_event = ::CreateEventW(&ready_event_attributes, TRUE, FALSE,
                                      ready_event_name.c_str());
  const DWORD ready_event_error = ::GetLastError();
  ::LocalFree(ready_event_security);
  if (ready_event == nullptr || ready_event_error == ERROR_ALREADY_EXISTS) {
    if (ready_event != nullptr) {
      ::CloseHandle(ready_event);
    }
    startup_diagnostics::Log(
        L"TUN elevation refused because the handoff event is unavailable");
    return "failed";
  }
  const std::wstring relaunch_parameters =
      std::wstring(kElevatedTunRelaunchArgument) + L" " +
      kElevatedTunUserArgumentPrefix + current_user_sid + L" " +
      kElevatedTunReadyArgumentPrefix + ready_event_name;

  SHELLEXECUTEINFOW request = {};
  request.cbSize = sizeof(request);
  request.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
  request.lpVerb = L"runas";
  request.lpFile = launcher_path.c_str();
  request.lpParameters = relaunch_parameters.c_str();
  request.lpDirectory = launcher_directory.c_str();
  request.nShow = SW_SHOWNORMAL;
  if (!::ShellExecuteExW(&request)) {
    const DWORD error = ::GetLastError();
    ::CloseHandle(ready_event);
    if (error == ERROR_CANCELLED) {
      startup_diagnostics::Log(L"TUN elevation was cancelled by the user");
      return "cancelled";
    }
    startup_diagnostics::Log(
        L"ShellExecuteExW failed while requesting TUN elevation: " +
        std::to_wstring(error));
    return "failed";
  }
  if (request.hProcess == nullptr) {
    ::CloseHandle(ready_event);
    startup_diagnostics::Log(
        L"Elevated TUN launcher did not return a process handle");
    return "failed";
  }
  HANDLE handoff_handles[] = {ready_event, request.hProcess};
  const DWORD handoff_result = ::WaitForMultipleObjects(
      2, handoff_handles, FALSE, kElevatedLauncherValidationMilliseconds);
  if (handoff_result == WAIT_OBJECT_0) {
    ::CloseHandle(ready_event);
    ::CloseHandle(request.hProcess);
    startup_diagnostics::Log(L"Elevated TUN replacement launcher accepted");
    return "launched";
  }
  if (handoff_result == WAIT_OBJECT_0 + 1) {
    DWORD exit_code = EXIT_FAILURE;
    if (!::GetExitCodeProcess(request.hProcess, &exit_code)) {
      exit_code = ::GetLastError();
    }
    ::CloseHandle(ready_event);
    ::CloseHandle(request.hProcess);
    startup_diagnostics::Log(
        L"Elevated TUN launcher exited before accepting the handoff: " +
        std::to_wstring(exit_code));
    return exit_code == ERROR_ACCESS_DENIED ? "standardUser" : "failed";
  }
  if (handoff_result != WAIT_TIMEOUT) {
    const DWORD error = ::GetLastError();
    ::CloseHandle(ready_event);
    ::CloseHandle(request.hProcess);
    startup_diagnostics::Log(
        L"Unable to validate the elevated TUN launcher: " +
        std::to_wstring(error));
    return "failed";
  }
  ::CloseHandle(ready_event);
  ::CloseHandle(request.hProcess);
  startup_diagnostics::Log(
      L"Elevated TUN launcher did not accept the handoff in time");
  return "failed";
}

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
  tun_elevation_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.ssrvpn.windows/tun_elevation",
          &flutter::StandardMethodCodec::GetInstance());
  tun_elevation_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "queryElevationState") {
          result->Success(flutter::EncodableValue(
              ElevationStateName(QueryProcessElevationState())));
          return;
        }
        if (call.method_name() == "requestTunElevationRelaunch") {
          result->Success(
              flutter::EncodableValue(RequestElevatedTunRelaunch()));
          return;
        }
        result->NotImplemented();
      });
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
  tun_elevation_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Proxy recovery must run before plugins get a chance to consume the
  // shutdown message and return early.
  if (message == WM_ENDSESSION && wparam != FALSE) {
    RestoreOwnedWindowsProxy();
  }

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
