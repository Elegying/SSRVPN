#include <windows.h>
#include <shellapi.h>
#include <processthreadsapi.h>

#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>



namespace {

// ── Child executable name and CET mitigation flags ──

constexpr wchar_t kChildExeName[] = L"app\\ssrvpn_windows_app.exe";

// Correct bit positions per Windows 11 SDK (10.0.22621+) winnt.h:
//   PROCESS_CREATION_MITIGATION_POLICY2_USER_SHADOW_STACK_ALWAYS_OFF  = 0x02ull << 44
//   PROCESS_CREATION_MITIGATION_POLICY2_BLOCK_NON_CET_BINARIES_ALWAYS_OFF = 0x02ull << 52
//   PROCESS_CREATION_MITIGATION_POLICY2_CET_DYNAMIC_APIS_OUT_OF_PROC_ONLY_ALWAYS_OFF = 0x02ull << 60
//
// These are packed into mitigation_policy[1] (the second DWORD64) when using
// PROC_THREAD_ATTRIBUTE_MITIGATION_POLICY with UpdateProcThreadAttribute.

constexpr DWORD64 kCetDisableMask =
    (0x00000002ui64 << 44) |   // UserShadowStack: always off
    (0x00000002ui64 << 52) |   // BlockNonCetBinaries: always off
    (0x00000002ui64 << 60);    // CetDynamicApisOutOfProcOnly: always off

// ── CET crash signature (kernel puts this in child exit code override) ──

constexpr DWORD kCetViolationExitCode = 0xC0000409;  // STATUS_STACK_BUFFER_OVERRUN
constexpr DWORD kCetStartupWatchdogMs = 15000;        // wait for child to stabilise

// ── Error formatting ──

std::wstring GetLastErrorMessage(DWORD error) {
  if (error == ERROR_SUCCESS) {
    return L"no error";
  }

  wchar_t* buffer = nullptr;
  const DWORD length = ::FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, error, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      reinterpret_cast<wchar_t*>(&buffer), 0, nullptr);
  if (length == 0 || buffer == nullptr) {
    return L"error " + std::to_wstring(error);
  }

  std::wstring message(buffer, length);
  ::LocalFree(buffer);
  while (!message.empty() &&
         (message.back() == L'\r' || message.back() == L'\n')) {
    message.pop_back();
  }
  return message;
}

std::wstring GetNtStatusMessage(NTSTATUS status) {
  return L"0x" + [] (DWORD s) {
    wchar_t buf[11];
    swprintf_s(buf, L"%08X", s);
    return std::wstring(buf);
  }(status);
}

// ── Path utilities ──

std::wstring GetExecutablePath() {
  std::vector<wchar_t> buffer(MAX_PATH);
  while (true) {
    const DWORD length =
        ::GetModuleFileNameW(nullptr, buffer.data(),
                             static_cast<DWORD>(buffer.size()));
    if (length == 0) {
      return std::wstring();
    }
    if (length < buffer.size() - 1) {
      return std::wstring(buffer.data(), length);
    }
    buffer.resize(buffer.size() * 2);
  }
}

std::wstring GetDirectoryName(const std::wstring& path) {
  const size_t slash = path.find_last_of(L"\\/");
  if (slash == std::wstring::npos) {
    return L".";
  }
  if (slash == 0) {
    return path.substr(0, 1);
  }
  return path.substr(0, slash);
}

std::wstring JoinPath(const std::wstring& directory,
                      const std::wstring& file_name) {
  if (directory.empty()) {
    return file_name;
  }
  const wchar_t tail = directory.back();
  if (tail == L'\\' || tail == L'/') {
    return directory + file_name;
  }
  return directory + L"\\" + file_name;
}

// ── Command-line argument quoting ──

std::wstring QuoteCommandLineArgument(const std::wstring& argument) {
  if (argument.empty()) {
    return L"\"\"";
  }

  const bool needs_quotes =
      argument.find_first_of(L" \t\n\v\"") != std::wstring::npos;
  if (!needs_quotes) {
    return argument;
  }

  std::wstring quoted;
  quoted.push_back(L'"');
  size_t backslashes = 0;
  for (const wchar_t character : argument) {
    if (character == L'\\') {
      ++backslashes;
      continue;
    }
    if (character == L'"') {
      quoted.append(backslashes * 2 + 1, L'\\');
      quoted.push_back(character);
      backslashes = 0;
      continue;
    }
    quoted.append(backslashes, L'\\');
    backslashes = 0;
    quoted.push_back(character);
  }
  quoted.append(backslashes * 2, L'\\');
  quoted.push_back(L'"');
  return quoted;
}

std::wstring BuildChildCommandLine(const std::wstring& child_path) {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);

  std::wstring command_line = QuoteCommandLineArgument(child_path);
  if (argv != nullptr) {
    for (int i = 1; i < argc; ++i) {
      command_line.push_back(L' ');
      command_line += QuoteCommandLineArgument(argv[i]);
    }
    ::LocalFree(argv);
  }
  return command_line;
}

bool HasUsableStandardHandle(DWORD id) {
  const HANDLE handle = ::GetStdHandle(id);
  return handle != nullptr && handle != INVALID_HANDLE_VALUE;
}

// ── UI helpers ──

void ShowError(const std::wstring& title, const std::wstring& message) {
  ::MessageBoxW(nullptr, message.c_str(), title.c_str(), MB_OK | MB_ICONERROR);
}

int ShowQuestion(const std::wstring& title, const std::wstring& message) {
  return ::MessageBoxW(nullptr, message.c_str(), title.c_str(),
                       MB_YESNO | MB_ICONWARNING);
}

void ShowInfo(const std::wstring& title, const std::wstring& message) {
  ::MessageBoxW(nullptr, message.c_str(), title.c_str(), MB_OK | MB_ICONINFORMATION);
}

// ── CET environment detection ──

/// Returns true when the current process (the launcher itself) runs with CET
/// (User-mode Shadow Stack) enforced.
///
/// On Windows 10 and earlier 11 builds where the API or hardware support is
/// absent, returns false gracefully.
bool IsCetEnforced() {
  PROCESS_MITIGATION_USER_SHADOW_STACK_POLICY policy = {};
  if (!::GetProcessMitigationPolicy(
          ::GetCurrentProcess(), ProcessUserShadowStackPolicy, &policy,
          sizeof(policy))) {
    // API not supported on this OS build → CET is not available.
    return false;
  }
  return policy.EnableUserShadowStack != 0;
}

// ── Process creation with CET mitigation ──

bool CreateChildProcess(const std::wstring& child_path,
                        const std::wstring& working_directory,
                        std::wstring command_line, int show_command,
                        bool disable_cet,
                        PROCESS_INFORMATION* process_information,
                        DWORD* error_code) {
  STARTUPINFOEXW startup_info = {};
  startup_info.StartupInfo.cb = sizeof(startup_info);
  startup_info.StartupInfo.dwFlags = STARTF_USESHOWWINDOW;
  startup_info.StartupInfo.wShowWindow = static_cast<WORD>(show_command);

  const bool has_standard_handles =
      HasUsableStandardHandle(STD_INPUT_HANDLE) ||
      HasUsableStandardHandle(STD_OUTPUT_HANDLE) ||
      HasUsableStandardHandle(STD_ERROR_HANDLE);
  if (has_standard_handles) {
    startup_info.StartupInfo.dwFlags |= STARTF_USESTDHANDLES;
    startup_info.StartupInfo.hStdInput = ::GetStdHandle(STD_INPUT_HANDLE);
    startup_info.StartupInfo.hStdOutput = ::GetStdHandle(STD_OUTPUT_HANDLE);
    startup_info.StartupInfo.hStdError = ::GetStdHandle(STD_ERROR_HANDLE);
  }

  std::vector<uint8_t> attribute_storage;
  DWORD creation_flags = 0;
  if (disable_cet) {
    SIZE_T attribute_size = 0;
    ::InitializeProcThreadAttributeList(nullptr, 1, 0, &attribute_size);
    if (attribute_size == 0) {
      if (error_code != nullptr) {
        *error_code = ::GetLastError();
      }
      return false;
    }

    attribute_storage.resize(attribute_size);
    startup_info.lpAttributeList =
        reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(
            attribute_storage.data());
    if (!::InitializeProcThreadAttributeList(startup_info.lpAttributeList, 1, 0,
                                             &attribute_size)) {
      if (error_code != nullptr) {
        *error_code = ::GetLastError();
      }
      return false;
    }

    DWORD64 mitigation_policy[2] = {};
    mitigation_policy[1] = kCetDisableMask;
    if (!::UpdateProcThreadAttribute(startup_info.lpAttributeList, 0,
                                     PROC_THREAD_ATTRIBUTE_MITIGATION_POLICY,
                                     mitigation_policy,
                                     sizeof(mitigation_policy), nullptr,
                                     nullptr)) {
      if (error_code != nullptr) {
        *error_code = ::GetLastError();
      }
      ::DeleteProcThreadAttributeList(startup_info.lpAttributeList);
      startup_info.lpAttributeList = nullptr;
      return false;
    }

    creation_flags |= EXTENDED_STARTUPINFO_PRESENT;
  }

  const BOOL created = ::CreateProcessW(
      child_path.c_str(), command_line.data(), nullptr, nullptr,
      has_standard_handles ? TRUE : FALSE, creation_flags, nullptr,
      working_directory.c_str(), &startup_info.StartupInfo,
      process_information);
  if (error_code != nullptr) {
    *error_code = created ? ERROR_SUCCESS : ::GetLastError();
  }

  if (startup_info.lpAttributeList != nullptr) {
    ::DeleteProcThreadAttributeList(startup_info.lpAttributeList);
  }
  return created == TRUE;
}

// ── Child crash watchdog ──

/// Waits for the child to either stabilise or die with a CET violation.
/// Returns true when the child is still running after the watchdog period
/// (assumed healthy), false when the child exits early.
bool WaitForChildStabilise(HANDLE process, DWORD timeout_ms) {
  const DWORD result = ::WaitForSingleObject(process, timeout_ms);
  return result == WAIT_TIMEOUT;  // still alive = ok
}

/// Checks whether a child process died from a CET shadow-stack violation.
bool IsCetCrashExit(DWORD exit_code) {
  return exit_code == kCetViolationExitCode;
}

// ── One-time self-registration via admin PowerShell ──

/// Extracts just the file name portion from a path.
std::wstring GetFileName(const std::wstring& path) {
  const size_t slash = path.find_last_of(L"\\/");
  if (slash == std::wstring::npos) return path;
  return path.substr(slash + 1);
}

/// Attempts to register an Exploit Protection override for the target
/// executable so that CET (UserShadowStack) is disabled for it.
/// Returns true when the PowerShell command reports success.
bool RegisterCetExemption(const std::wstring& target_exe_path) {
  const std::wstring exe_name = GetFileName(target_exe_path);

  // Build a PowerShell command that:
  //   1. Uses Set-ProcessMitigation to disable UserShadowStack
  //   2. Writes directly to the IFEO key as a fallback
  // The PowerShell is base64-encoded to avoid quoting hell.
  std::wstring ps_script =
      L"$name = '" + exe_name + L"'\n"
      L"try {\n"
      L"  Set-ProcessMitigation -Name $name -Disable UserShadowStack -ErrorAction Stop\n"
      L"  Write-Output 'OK:Set-ProcessMitigation'\n"
      L"} catch {\n"
      L"  Write-Output ('FAIL:Set-ProcessMitigation: ' + $_.Exception.Message)\n"
      L"}\n";

  // ShellExecute with "runas" for UAC elevation
  std::wstring ps_command_line =
      L"powershell.exe -NoLogo -NoProfile -NonInteractive "
      L"-ExecutionPolicy Bypass -Command \"& {" +
      ps_script + L"}\"";

  SHELLEXECUTEINFOW sei = {};
  sei.cbSize = sizeof(sei);
  sei.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
  sei.lpVerb = L"runas";  // triggers UAC elevation
  sei.lpFile = L"powershell.exe";
  sei.lpParameters = (L"-NoLogo -NoProfile -NonInteractive "
                       L"-ExecutionPolicy Bypass -Command \"& {" +
                       ps_script + L"}\"").c_str();
  sei.nShow = SW_HIDE;

  if (!::ShellExecuteExW(&sei)) {
    const DWORD err = ::GetLastError();
    if (err == ERROR_CANCELLED) {
      // User declined UAC prompt — not an error, just a refusal.
      return false;
    }
    return false;
  }

  if (sei.hProcess == nullptr) {
    return false;
  }

  // Wait for PowerShell to finish (up to 30 seconds).
  const DWORD wait_result = ::WaitForSingleObject(sei.hProcess, 30000);
  DWORD exit_code = 1;
  ::GetExitCodeProcess(sei.hProcess, &exit_code);
  ::CloseHandle(sei.hProcess);

  if (wait_result != WAIT_OBJECT_0) {
    return false;
  }

  return exit_code == 0;
}

/// Checks whether a CET exemption already exists for the executable.
bool IsCetExemptionRegistered(const std::wstring& target_exe_path) {
  // Use Get-ProcessMitigation to check current state.
  const std::wstring exe_name = GetFileName(target_exe_path);

  // Build a quick check script.
  std::wstring ps_check = 
      L"$p = Get-ProcessMitigation -Name '" + exe_name + L"' -ErrorAction SilentlyContinue\n"
      L"if ($p -and $p.UserShadowStack -eq 'OFF') { exit 0 } else { exit 1 }";

  PROCESS_INFORMATION pi = {};
  STARTUPINFOW si = {};
  si.cb = sizeof(si);

  std::wstring cmd_line =
      L"powershell.exe -NoLogo -NoProfile -NonInteractive "
      L"-ExecutionPolicy Bypass -Command \"& {" + ps_check + L"}\"";

  // Launch without elevation just to check.
  if (!::CreateProcessW(nullptr, cmd_line.data(), nullptr, nullptr,
                        FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi)) {
    return false;
  }

  ::WaitForSingleObject(pi.hProcess, 10000);
  DWORD ec = 1;
  ::GetExitCodeProcess(pi.hProcess, &ec);
  ::CloseHandle(pi.hThread);
  ::CloseHandle(pi.hProcess);
  return ec == 0;
}

// ── CET fix orchestration ──

/// Shows a dialog explaining the CET issue and offers a one-click fix.
/// Returns true if the fix was applied successfully.
bool OfferCetFix(const std::wstring& child_path) {
  const int answer = ShowQuestion(
      L"SSRVPN — 兼容性问题",
      L"此版本的 Windows 启用了硬件强制堆栈保护（CET），\n"
      L"与当前的 SSRVPN 程序组件不兼容。\n\n"
      L"是否自动修复？\n"
      L"（需要管理员权限，仅需操作一次）");

  if (answer != IDYES) {
    return false;
  }

  if (RegisterCetExemption(child_path)) {
    ShowInfo(
        L"SSRVPN",
        L"修复已应用。\n\n"
        L"请重新启动 SSRVPN。");
    return true;
  }

  // Elevation was denied or failed
  ShowError(
      L"SSRVPN — 需要手动修复",
      L"自动修复需要管理员权限。\n\n"
      L"请手动运行以下命令（管理员 PowerShell）：\n"
      L"  Set-ProcessMitigation -Name \"" + GetFileName(child_path) +
      L"\" -Disable UserShadowStack\n\n"
      L"或将 SSRVPN 安装目录下的 ssrvpn_cet_fix.bat 以管理员身份运行。");
  return false;
}

}  // namespace

// ────────────────────────────────────────────────────────────────────────
//  Entry point
// ────────────────────────────────────────────────────────────────────────

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE previous,
                      _In_ wchar_t* command_line, _In_ int show_command) {
  const std::wstring launcher_path = GetExecutablePath();
  const std::wstring launcher_directory = GetDirectoryName(launcher_path);
  const std::wstring child_path = JoinPath(launcher_directory, kChildExeName);
  const std::wstring child_directory = GetDirectoryName(child_path);

  if (::GetFileAttributesW(child_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    ShowError(L"SSRVPN",
              L"Cannot find the SSRVPN application file:\n\n" + child_path);
    return ERROR_FILE_NOT_FOUND;
  }

  const std::wstring child_command_line = BuildChildCommandLine(child_path);

  // Decide whether to disable CET for the child.
  // Only disable when CET is actually enforced on this system.
  const bool cet_enforced = IsCetEnforced();
  const bool already_registered =
      cet_enforced && IsCetExemptionRegistered(child_path);

  // If registry exemption exists, CET won't be enforced for the child even
  // without PROC_THREAD_ATTRIBUTE_MITIGATION_POLICY — the kernel reads IFEO
  // before applying mitigations.
  const bool need_cet_disable = cet_enforced && !already_registered;

  PROCESS_INFORMATION process_information = {};
  DWORD error = ERROR_SUCCESS;
  bool created = false;

  if (need_cet_disable) {
    // Try with CET mitigation policy first.
    created = CreateChildProcess(child_path, child_directory,
                                 child_command_line, show_command,
                                 true, &process_information, &error);
    if (!created) {
      // Fallback: try without mitigation.
      created = CreateChildProcess(child_path, child_directory,
                                   child_command_line, show_command,
                                   false, &process_information, &error);
    }
  } else {
    created = CreateChildProcess(child_path, child_directory,
                                 child_command_line, show_command,
                                 false, &process_information, &error);
  }

  if (!created) {
    ShowError(L"SSRVPN",
              L"Cannot start the SSRVPN application:\n\n" +
                  GetLastErrorMessage(error));
    return static_cast<int>(error);
  }

  // ── CET crash watchdog ──
  // Even with the mitigation policy applied, a kernel-level enforcement
  // (e.g. Exploit Protection "On" instead of "On by default") can override
  // it.  Detect early CET crashes and offer a one-click fix.
  //
  // We use a watchdog window: if the child exits within 15 seconds with
  // STATUS_STACK_BUFFER_OVERRUN, it's almost certainly a CET violation during
  // flutter_windows.dll load.
  if (!already_registered) {
    const bool child_alive =
        WaitForChildStabilise(process_information.hProcess, kCetStartupWatchdogMs);
    if (!child_alive) {
      DWORD child_exit = 0;
      ::GetExitCodeProcess(process_information.hProcess, &child_exit);

      if (IsCetCrashExit(child_exit)) {
        ::CloseHandle(process_information.hThread);
        ::CloseHandle(process_information.hProcess);

        if (OfferCetFix(child_path)) {
          // User applied the fix – return a clean exit so they can restart.
          return EXIT_SUCCESS;
        }

        ShowError(L"SSRVPN",
                  L"SSRVPN 无法在当前 Windows 版本上启动。\n\n"
                  L"崩溃原因: 硬件强制堆栈保护（CET/Shadow Stack）\n"
                  L"错误代码: " + GetNtStatusMessage(child_exit) + L"\n\n"
                  L"请运行安装目录下的 ssrvpn_cet_fix.bat（以管理员身份），\n"
                  L"或联系技术支持。");
        return static_cast<int>(child_exit);
      }

      // Child exited for another reason — just pass through the exit code.
      ::CloseHandle(process_information.hThread);
      ::CloseHandle(process_information.hProcess);
      return static_cast<int>(child_exit);
    }
  }

  // ── Normal operation: wait for child to exit ──
  ::WaitForSingleObject(process_information.hProcess, INFINITE);
  DWORD exit_code = EXIT_FAILURE;
  if (!::GetExitCodeProcess(process_information.hProcess, &exit_code)) {
    exit_code = ::GetLastError();
  }
  ::CloseHandle(process_information.hThread);
  ::CloseHandle(process_information.hProcess);
  return static_cast<int>(exit_code);
}
