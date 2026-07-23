#include <windows.h>
#include <sddl.h>
#include <shellapi.h>

#include <cstdlib>
#include <cwchar>
#include <string>
#include <vector>

#include "guardian_restart.h"
#include "launcher_instance_control.h"
#include "system_proxy_recovery.h"

namespace {

constexpr wchar_t kChildExeName[] = L"ssrvpn_windows_app.exe";
constexpr wchar_t kAppMutexName[] = L"Local\\SSRVPN_Windows_SingleInstance";
constexpr wchar_t kLauncherMutexName[] = L"Local\\SSRVPN_Windows_Launcher";
constexpr wchar_t kGuardianMutexName[] = L"Local\\SSRVPN_Windows_LauncherGuardian";
constexpr wchar_t kProxyRecoveryMutexName[] = L"Local\\SSRVPN_Windows_ProxyRecovery";
constexpr wchar_t kProcessJobName[] = L"Local\\SSRVPN_Windows_ProcessJob";
constexpr wchar_t kGuardianArgument[] = L"--ssrvpn-native-guardian";
constexpr wchar_t kGuardianReadyPrefix[] = L"Local\\SSRVPN_Windows_GuardianReady_";
constexpr wchar_t kGuardianCommitPrefix[] = L"Local\\SSRVPN_Windows_GuardianCommit_";
constexpr wchar_t kElevatedTunRelaunchArgument[] =
    L"--ssrvpn-elevated-tun-relaunch";
constexpr wchar_t kElevatedTunUserArgumentPrefix[] =
    L"--ssrvpn-elevated-tun-user=";
constexpr wchar_t kElevatedTunReadyArgumentPrefix[] =
    L"--ssrvpn-elevated-tun-ready=";
constexpr wchar_t kElevatedTunReadyEventPrefix[] =
    L"Local\\SSRVPN_Windows_TunElevationReady_";
constexpr DWORD kElevationRelaunchTotalWaitMilliseconds = 90000;

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

bool HasExactCommandLineArgument(const wchar_t* expected) {
  if (expected == nullptr) {
    return false;
  }
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return false;
  }
  bool found = false;
  for (int i = 1; i < argc; ++i) {
    if (::wcscmp(argv[i], expected) == 0) {
      found = true;
      break;
    }
  }
  ::LocalFree(argv);
  return found;
}

std::wstring CommandLineArgumentValue(const wchar_t* prefix) {
  if (prefix == nullptr) {
    return std::wstring();
  }
  const size_t prefix_length = ::wcslen(prefix);
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::wstring();
  }
  std::wstring value;
  for (int i = 1; i < argc; ++i) {
    if (::wcsncmp(argv[i], prefix, prefix_length) == 0) {
      value.assign(argv[i] + prefix_length);
      break;
    }
  }
  ::LocalFree(argv);
  return value;
}

bool IsCurrentProcessElevated() {
  HANDLE token = nullptr;
  if (!::OpenProcessToken(::GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return false;
  }
  TOKEN_ELEVATION elevation = {};
  DWORD bytes = 0;
  const bool elevated =
      ::GetTokenInformation(token, TokenElevation, &elevation,
                            sizeof(elevation), &bytes) != FALSE &&
      elevation.TokenIsElevated != 0;
  ::CloseHandle(token);
  return elevated;
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
  std::vector<BYTE> token_user_buffer(bytes);
  if (!::GetTokenInformation(token, TokenUser, token_user_buffer.data(),
                             bytes, &bytes)) {
    ::CloseHandle(token);
    return std::wstring();
  }
  ::CloseHandle(token);

  const auto* token_user =
      reinterpret_cast<const TOKEN_USER*>(token_user_buffer.data());
  wchar_t* sid_string = nullptr;
  if (!::ConvertSidToStringSidW(token_user->User.Sid, &sid_string) ||
      sid_string == nullptr) {
    return std::wstring();
  }
  const std::wstring result(sid_string);
  ::LocalFree(sid_string);
  return result;
}

DWORD RemainingWaitMilliseconds(ULONGLONG deadline) {
  const ULONGLONG now = ::GetTickCount64();
  if (now >= deadline) {
    return 0;
  }
  const ULONGLONG remaining = deadline - now;
  return remaining > MAXDWORD ? MAXDWORD : static_cast<DWORD>(remaining);
}

bool HasUsableStandardHandle(DWORD id) {
  const HANDLE handle = ::GetStdHandle(id);
  return handle != nullptr && handle != INVALID_HANDLE_VALUE;
}

HANDLE CreateProcessJob() {
  HANDLE process_job = ::CreateJobObjectW(nullptr, kProcessJobName);
  if (process_job != nullptr &&
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    // A fixed-name job can be created before SSRVPN starts. Never attach the
    // app to an object whose membership was not established by this launcher.
    ::CloseHandle(process_job);
    ::SetLastError(ERROR_ALREADY_EXISTS);
    return nullptr;
  }
  return process_job;
}

bool RestoreProxyForProcessCleanup(
    const WindowsProxyTransactionLock& transaction_lock) {
  return RestoreOwnedWindowsProxy(transaction_lock) ||
         IsOwnedWindowsProxySafeToStop(transaction_lock);
}

bool RestoreProxyForProcessCleanup() {
  return RestoreOrConfirmOwnedWindowsProxySafeToStop();
}

bool ProcessIsOutsideJob(HANDLE process, HANDLE process_job,
                         DWORD* error_code) {
  BOOL belongs_to_job = FALSE;
  if (!::IsProcessInJob(process, process_job, &belongs_to_job)) {
    if (error_code != nullptr) *error_code = ::GetLastError();
    return false;
  }
  if (belongs_to_job) {
    if (error_code != nullptr) *error_code = ERROR_INVALID_OWNER;
    return false;
  }
  if (error_code != nullptr) *error_code = ERROR_SUCCESS;
  return true;
}

bool ParseGuardianArguments(DWORD* child_process_id,
                            DWORD* child_thread_id,
                            std::wstring* ready_event_name,
                            std::wstring* commit_event_name) {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  bool valid = false;
  if (argv != nullptr && argc == 6 &&
      ::CompareStringOrdinal(argv[1], -1, kGuardianArgument, -1, TRUE) ==
          CSTR_EQUAL &&
      std::wcsncmp(argv[4], kGuardianReadyPrefix,
                   std::wcslen(kGuardianReadyPrefix)) == 0 &&
      std::wcsncmp(argv[5], kGuardianCommitPrefix,
                   std::wcslen(kGuardianCommitPrefix)) == 0) {
    wchar_t* process_end = nullptr;
    wchar_t* thread_end = nullptr;
    const unsigned long parsed_process =
        std::wcstoul(argv[2], &process_end, 10);
    const unsigned long parsed_thread =
        std::wcstoul(argv[3], &thread_end, 10);
    if (parsed_process != 0 && process_end != argv[2] &&
        *process_end == L'\0' && thread_end != argv[3] &&
        *thread_end == L'\0') {
      *child_process_id = static_cast<DWORD>(parsed_process);
      *child_thread_id = static_cast<DWORD>(parsed_thread);
      *ready_event_name = argv[4];
      *commit_event_name = argv[5];
      valid = true;
    }
  }
  if (argv != nullptr) {
    ::LocalFree(argv);
  }
  return valid;
}

bool ArmKillOnJobCloseAndRelease(HANDLE* process_job,
                                 HANDLE child_process);
void MakeSafeDisconnectVisible(HANDLE child_process);
HANDLE ShowErrorAsync(const std::wstring& title,
                      const std::wstring& message);

DWORD RestoreAndTerminateGuardedProcess(
    HANDLE child_process, HANDLE* process_job = nullptr,
    bool make_safe_disconnect_visible = false) {
  WindowsProxyTransactionLock transaction_lock;
  if (!transaction_lock.acquired() ||
      !RestoreProxyForProcessCleanup(transaction_lock)) {
    return ERROR_BUSY;
  }

  DWORD child_wait = ::WaitForSingleObject(child_process, 0);
  if (child_wait != WAIT_OBJECT_0 && make_safe_disconnect_visible) {
    MakeSafeDisconnectVisible(child_process);
  }

  DWORD termination_error = ERROR_NOT_FOUND;
  bool job_termination_requested = false;
  bool job_termination_confirmed = false;
  const bool job_confirmed_absent =
      process_job == nullptr || *process_job == nullptr;
  HANDLE termination_job = process_job == nullptr ? nullptr : *process_job;
  if (termination_job != nullptr) {
    if (::TerminateJobObject(termination_job, EXIT_FAILURE)) {
      job_termination_requested = true;
      const ULONGLONG deadline = ::GetTickCount64() + 5000;
      while (true) {
        JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting = {};
        if (!::QueryInformationJobObject(
                termination_job, JobObjectBasicAccountingInformation,
                &accounting, sizeof(accounting), nullptr)) {
          termination_error = ::GetLastError();
          break;
        }
        if (accounting.ActiveProcesses == 0) {
          job_termination_confirmed = true;
          break;
        }
        if (::GetTickCount64() >= deadline) {
          termination_error = ERROR_TIMEOUT;
          break;
        }
        ::Sleep(50);
      }
    } else {
      termination_error = ::GetLastError();
    }
  } else {
    termination_error = ERROR_NOT_FOUND;
  }

  child_wait = ::WaitForSingleObject(
      child_process, job_termination_requested ? 5000 : 0);
  if (child_wait == WAIT_TIMEOUT) {
    if (::TerminateProcess(child_process, EXIT_FAILURE)) {
      child_wait = ::WaitForSingleObject(child_process, 5000);
      if (child_wait != WAIT_OBJECT_0) {
        termination_error =
            child_wait == WAIT_TIMEOUT ? ERROR_TIMEOUT : ::GetLastError();
      }
    } else {
      termination_error = ::GetLastError();
    }
  } else if (child_wait == WAIT_FAILED) {
    termination_error = ::GetLastError();
  }

  if (child_wait == WAIT_OBJECT_0 &&
      (job_termination_confirmed || job_confirmed_absent)) {
    return RestoreProxyForProcessCleanup(transaction_lock) ? ERROR_SUCCESS
                                                           : ERROR_BUSY;
  }
  if (job_termination_requested && !job_termination_confirmed) {
    return ERROR_BUSY;
  }

  // Keep KILL_ON_JOB_CLOSE inside the same proxy transaction. Releasing the
  // lock before the final kill would let Dart re-enable the owned endpoint in
  // the gap and turn a safe disconnect into a dead localhost proxy.
  if (process_job != nullptr && *process_job != nullptr &&
      ArmKillOnJobCloseAndRelease(process_job, child_process)) {
    return RestoreProxyForProcessCleanup(transaction_lock) ? ERROR_SUCCESS
                                                           : ERROR_BUSY;
  }
  return termination_error;
}

DWORD RestoreAndTerminateGuardedProcessWithRetry(
    const std::wstring& child_path, HANDLE child_process,
    HANDLE* process_job) {
  DWORD retry_delay_ms = 250;
  while (true) {
    const DWORD cleanup_error =
        RestoreAndTerminateGuardedProcess(child_process, process_job);
    if (cleanup_error == ERROR_SUCCESS) {
      return ERROR_SUCCESS;
    }
    if (cleanup_error != ERROR_BUSY &&
        ::WaitForSingleObject(child_process, 0) != WAIT_OBJECT_0) {
      return cleanup_error;
    }
    RearmWindowsProxyRecoveryRunOnce(child_path.c_str());
    ::Sleep(retry_delay_ms);
    retry_delay_ms = retry_delay_ms < 2500 ? retry_delay_ms * 2 : 5000;
  }
}

bool ArmKillOnJobCloseAndRelease(HANDLE* process_job,
                                 HANDLE child_process) {
  if (process_job == nullptr || *process_job == nullptr) {
    return false;
  }

  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
  if (!::QueryInformationJobObject(
          *process_job, JobObjectExtendedLimitInformation, &limits,
          sizeof(limits), nullptr)) {
    return false;
  }
  limits.BasicLimitInformation.LimitFlags |=
      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!::SetInformationJobObject(
          *process_job, JobObjectExtendedLimitInformation, &limits,
          sizeof(limits))) {
    return false;
  }

  ::CloseHandle(*process_job);
  *process_job = nullptr;
  // Do not release the proxy transaction while a last-handle job kill may
  // still be pending. If another process owns a job handle, keep the app in
  // the already-visible safe-disconnect state until that reference closes.
  return ::WaitForSingleObject(child_process, INFINITE) == WAIT_OBJECT_0;
}

struct ProcessWindowLookup {
  DWORD process_id = 0;
  HWND window = nullptr;
};

BOOL CALLBACK FindProcessWindow(HWND window, LPARAM parameter) {
  auto* lookup = reinterpret_cast<ProcessWindowLookup*>(parameter);
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(window, &process_id);
  if (process_id != lookup->process_id ||
      ::GetWindow(window, GW_OWNER) != nullptr) {
    return TRUE;
  }
  lookup->window = window;
  return FALSE;
}

void MakeSafeDisconnectVisible(HANDLE child_process) {
  ProcessWindowLookup lookup = {::GetProcessId(child_process), nullptr};
  ::EnumWindows(FindProcessWindow, reinterpret_cast<LPARAM>(&lookup));

  constexpr wchar_t kDisconnectedTitle[] =
      L"SSRVPN - Windows system proxy disconnected";
  if (lookup.window != nullptr) {
    ::SendNotifyMessageW(lookup.window, WM_SETTEXT, 0,
                         reinterpret_cast<LPARAM>(kDisconnectedTitle));
    ::ShowWindowAsync(lookup.window, SW_RESTORE);
    FLASHWINFO flash = {sizeof(FLASHWINFO), lookup.window,
                        FLASHW_ALL | FLASHW_TIMERNOFG, 5, 0};
    ::FlashWindowEx(&flash);
  } else {
    HANDLE notice = ShowErrorAsync(
        L"SSRVPN system proxy disconnected",
        L"SSRVPN restored the Windows system proxy, but the remaining app "
        L"process could not be closed immediately. Traffic is no longer "
        L"using SSRVPN; close the app before reconnecting.");
    if (notice != nullptr) {
      ::CloseHandle(notice);
    }
  }
}

int RunGuardian(const std::wstring& child_path, DWORD child_process_id,
                DWORD child_thread_id,
                const std::wstring& ready_event_name,
                const std::wstring& commit_event_name) {
  HANDLE guardian_mutex =
      ::CreateMutexW(nullptr, FALSE, kGuardianMutexName);
  if (guardian_mutex == nullptr) {
    return static_cast<int>(::GetLastError());
  }
  const DWORD mutex_wait = ::WaitForSingleObject(guardian_mutex, 0);
  if (mutex_wait != WAIT_OBJECT_0 && mutex_wait != WAIT_ABANDONED) {
    const DWORD error = mutex_wait == WAIT_TIMEOUT ? ERROR_ALREADY_EXISTS
                                                   : ::GetLastError();
    ::CloseHandle(guardian_mutex);
    return static_cast<int>(error);
  }

  HANDLE child_process = nullptr;
  HANDLE child_thread = nullptr;
  HANDLE process_job = nullptr;
  HANDLE ready_event = nullptr;
  HANDLE commit_event = nullptr;
  const auto finish = [&](DWORD result) {
    if (commit_event != nullptr) {
      ::CloseHandle(commit_event);
    }
    if (ready_event != nullptr) {
      ::CloseHandle(ready_event);
    }
    if (process_job != nullptr) {
      ::CloseHandle(process_job);
    }
    if (child_thread != nullptr) {
      ::CloseHandle(child_thread);
    }
    if (child_process != nullptr) {
      ::CloseHandle(child_process);
    }
    ::ReleaseMutex(guardian_mutex);
    ::CloseHandle(guardian_mutex);
    return static_cast<int>(result);
  };

  child_process = ::OpenProcess(
      SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE,
      FALSE, child_process_id);
  if (child_process == nullptr ||
      !ProcessImageMatches(child_process, child_path)) {
    return finish(ERROR_ACCESS_DENIED);
  }
  process_job = ::OpenJobObjectW(
      JOB_OBJECT_TERMINATE | JOB_OBJECT_QUERY | JOB_OBJECT_SET_ATTRIBUTES,
      FALSE, kProcessJobName);
  if (process_job == nullptr) {
    return finish(::GetLastError());
  }
  DWORD security_error = ERROR_SUCCESS;
  if (!ProcessIsOutsideJob(::GetCurrentProcess(), process_job,
                           &security_error) ||
      !ProcessTokensHaveSecurityParity(::GetCurrentProcess(), child_process,
                                       &security_error)) {
    return finish(security_error);
  }
  BOOL belongs_to_job = FALSE;
  if (!::IsProcessInJob(child_process, process_job, &belongs_to_job) ||
      !belongs_to_job) {
    return finish(ERROR_INVALID_OWNER);
  }
  if (child_thread_id != 0) {
    child_thread = ::OpenThread(
        THREAD_SUSPEND_RESUME | THREAD_QUERY_LIMITED_INFORMATION, FALSE,
        child_thread_id);
    if (child_thread == nullptr ||
        ::GetProcessIdOfThread(child_thread) != child_process_id) {
      return finish(ERROR_INVALID_OWNER);
    }
  }
  ready_event =
      ::OpenEventW(EVENT_MODIFY_STATE, FALSE, ready_event_name.c_str());
  commit_event =
      ::OpenEventW(SYNCHRONIZE, FALSE, commit_event_name.c_str());
  if (ready_event == nullptr || commit_event == nullptr ||
      !::SetEvent(ready_event)) {
    return finish(::GetLastError());
  }
  ::CloseHandle(ready_event);
  ready_event = nullptr;

  HANDLE startup_handles[] = {commit_event, child_process};
  const DWORD startup_wait =
      ::WaitForMultipleObjects(2, startup_handles, FALSE, 5000);
  if (startup_wait == WAIT_TIMEOUT || startup_wait == WAIT_FAILED) {
    const DWORD startup_error =
        startup_wait == WAIT_TIMEOUT ? ERROR_TIMEOUT : ::GetLastError();
    const DWORD cleanup_error =
        RestoreAndTerminateGuardedProcessWithRetry(
            child_path, child_process, &process_job);
    if (cleanup_error != ERROR_SUCCESS &&
        ::WaitForSingleObject(child_process, 0) == WAIT_TIMEOUT) {
      ::OutputDebugStringW(
          L"SSRVPN guardian left the app suspended because safe startup "
          L"cleanup could not finish.\n");
    }
    return finish(cleanup_error == ERROR_SUCCESS ? startup_error
                                                  : cleanup_error);
  }
  if (startup_wait == WAIT_OBJECT_0) {
    if (child_thread != nullptr) {
      const DWORD previous_suspend_count = ::ResumeThread(child_thread);
      if (previous_suspend_count > 1) {
        const DWORD resume_error =
            previous_suspend_count == static_cast<DWORD>(-1)
                ? ::GetLastError()
                : ERROR_INVALID_STATE;
        ::OutputDebugStringW(
            (L"SSRVPN guardian could not resume the committed app safely: " +
             GetLastErrorMessage(resume_error) + L"\n")
                .c_str());
        const DWORD cleanup_error =
            RestoreAndTerminateGuardedProcessWithRetry(
                child_path, child_process, &process_job);
        return finish(cleanup_error == ERROR_SUCCESS ? resume_error
                                                      : cleanup_error);
      }
    }
    if (::WaitForSingleObject(child_process, INFINITE) != WAIT_OBJECT_0) {
      return finish(::GetLastError());
    }
  } else if (startup_wait != WAIT_OBJECT_0 + 1) {
    return finish(ERROR_INVALID_STATE);
  }
  DWORD exit_code = EXIT_FAILURE;
  if (!::GetExitCodeProcess(child_process, &exit_code)) {
    exit_code = ::GetLastError();
  }
  if (exit_code == ERROR_ALREADY_EXISTS) {
    return finish(ERROR_ALREADY_EXISTS);
  }

  return finish(
      RestoreAndTerminateGuardedProcessWithRetry(
          child_path, child_process, &process_job));
}

// ── UI helpers ──

void ShowError(const std::wstring& title, const std::wstring& message) {
  ::MessageBoxW(nullptr, message.c_str(), title.c_str(), MB_OK | MB_ICONERROR);
}

struct AsyncErrorMessage {
  std::wstring title;
  std::wstring message;
};

DWORD WINAPI ShowErrorThread(void* parameter) {
  auto* error = static_cast<AsyncErrorMessage*>(parameter);
  ::MessageBoxW(nullptr, error->message.c_str(), error->title.c_str(),
                MB_OK | MB_ICONERROR | MB_SETFOREGROUND | MB_TOPMOST);
  delete error;
  return ERROR_SUCCESS;
}

HANDLE ShowErrorAsync(const std::wstring& title,
                      const std::wstring& message) {
  auto* error = new AsyncErrorMessage{title, message};
  HANDLE thread =
      ::CreateThread(nullptr, 0, ShowErrorThread, error, 0, nullptr);
  if (thread == nullptr) {
    delete error;
  }
  return thread;
}

bool CreateDetachedGuardianProcess(
    const std::wstring& launcher_path,
    const std::wstring& launcher_directory, DWORD child_process_id,
    DWORD child_thread_id,
    const std::wstring& ready_event_name,
    const std::wstring& commit_event_name,
    PROCESS_INFORMATION* process_information, DWORD* error_code) {
  *process_information = {};
  HWND shell_window = ::GetShellWindow();
  DWORD shell_process_id = 0;
  if (shell_window != nullptr) {
    ::GetWindowThreadProcessId(shell_window, &shell_process_id);
  }
  if (shell_process_id == 0) {
    if (error_code != nullptr) {
      *error_code = ERROR_NOT_FOUND;
    }
    return false;
  }

  DWORD current_session_id = 0;
  DWORD shell_session_id = 0;
  if (!::ProcessIdToSessionId(::GetCurrentProcessId(), &current_session_id) ||
      !::ProcessIdToSessionId(shell_process_id, &shell_session_id) ||
      current_session_id != shell_session_id) {
    if (error_code != nullptr) {
      *error_code = ERROR_INVALID_OWNER;
    }
    return false;
  }

  HANDLE shell_process =
      ::OpenProcess(PROCESS_CREATE_PROCESS | PROCESS_QUERY_LIMITED_INFORMATION,
                    FALSE, shell_process_id);
  if (shell_process == nullptr) {
    if (error_code != nullptr) {
      *error_code = ::GetLastError();
    }
    return false;
  }

  std::vector<wchar_t> windows_directory(32768);
  const UINT windows_length = ::GetWindowsDirectoryW(
      windows_directory.data(), static_cast<UINT>(windows_directory.size()));
  const bool windows_directory_valid =
      windows_length > 0 &&
      windows_length < static_cast<UINT>(windows_directory.size());
  const std::wstring explorer_path =
      windows_directory_valid
          ? JoinPath(std::wstring(windows_directory.data(), windows_length),
                     L"explorer.exe")
          : std::wstring();
  if (explorer_path.empty() ||
      !ProcessImageMatches(shell_process, explorer_path)) {
    ::CloseHandle(shell_process);
    if (error_code != nullptr) {
      *error_code = ERROR_INVALID_OWNER;
    }
    return false;
  }

  HANDLE current_token = nullptr;
  if (!::OpenProcessToken(::GetCurrentProcess(),
                          TOKEN_QUERY | TOKEN_DUPLICATE |
                              TOKEN_ASSIGN_PRIMARY,
                          &current_token)) {
    const DWORD error = ::GetLastError();
    ::CloseHandle(shell_process);
    if (error_code != nullptr) {
      *error_code = error;
    }
    return false;
  }

  SIZE_T attribute_bytes = 0;
  ::InitializeProcThreadAttributeList(nullptr, 1, 0, &attribute_bytes);
  std::vector<unsigned char> attribute_storage(attribute_bytes);
  auto* attribute_list = reinterpret_cast<PPROC_THREAD_ATTRIBUTE_LIST>(
      attribute_storage.data());
  if (attribute_bytes == 0 ||
      !::InitializeProcThreadAttributeList(attribute_list, 1, 0,
                                           &attribute_bytes)) {
    const DWORD error = ::GetLastError();
    ::CloseHandle(current_token);
    ::CloseHandle(shell_process);
    if (error_code != nullptr) {
      *error_code = error;
    }
    return false;
  }
  // Explorer parenting keeps this hidden watchdog out of `taskkill /T` on
  // the visible launcher. Supply the launcher's primary token explicitly so
  // the parent attribute cannot silently de-elevate the guardian.
  if (!::UpdateProcThreadAttribute(
          attribute_list, 0, PROC_THREAD_ATTRIBUTE_PARENT_PROCESS,
          &shell_process, sizeof(shell_process), nullptr, nullptr)) {
    const DWORD error = ::GetLastError();
    ::DeleteProcThreadAttributeList(attribute_list);
    ::CloseHandle(current_token);
    ::CloseHandle(shell_process);
    if (error_code != nullptr) {
      *error_code = error;
    }
    return false;
  }

  STARTUPINFOEXW startup_info = {};
  startup_info.StartupInfo.cb = sizeof(startup_info);
  startup_info.StartupInfo.dwFlags = STARTF_USESHOWWINDOW;
  startup_info.StartupInfo.wShowWindow = SW_HIDE;
  startup_info.lpAttributeList = attribute_list;
  std::wstring guardian_command_line =
      QuoteCommandLineArgument(launcher_path) + L" " +
      QuoteCommandLineArgument(kGuardianArgument) + L" " +
      std::to_wstring(child_process_id) + L" " +
      std::to_wstring(child_thread_id) + L" " +
      QuoteCommandLineArgument(ready_event_name) + L" " +
      QuoteCommandLineArgument(commit_event_name);
  PROCESS_INFORMATION guardian_information = {};
  const BOOL created = ::CreateProcessAsUserW(
      current_token, launcher_path.c_str(), guardian_command_line.data(),
      nullptr, nullptr, FALSE,
      EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW, nullptr,
      launcher_directory.c_str(), &startup_info.StartupInfo,
      &guardian_information);
  const DWORD error = created ? ERROR_SUCCESS : ::GetLastError();
  ::DeleteProcThreadAttributeList(attribute_list);
  ::CloseHandle(current_token);
  ::CloseHandle(shell_process);
  if (!created) {
    if (error_code != nullptr) {
      *error_code = error;
    }
    return false;
  }

  DWORD validation_error = ERROR_SUCCESS;
  HANDLE process_job =
      ::OpenJobObjectW(JOB_OBJECT_QUERY, FALSE, kProcessJobName);
  const DWORD process_job_error =
      process_job == nullptr ? ::GetLastError() : ERROR_SUCCESS;
  const bool guardian_is_safe =
      ProcessTokensHaveSecurityParity(::GetCurrentProcess(),
                                      guardian_information.hProcess,
                                      &validation_error) &&
      process_job != nullptr &&
      ProcessIsOutsideJob(guardian_information.hProcess, process_job,
                          &validation_error);
  if (process_job == nullptr && validation_error == ERROR_SUCCESS) {
    validation_error = process_job_error;
  }
  if (process_job != nullptr) {
    ::CloseHandle(process_job);
  }
  if (!guardian_is_safe) {
    if (validation_error == ERROR_SUCCESS) {
      validation_error = ERROR_ACCESS_DENIED;
    }
    ::TerminateProcess(guardian_information.hProcess, validation_error);
    ::WaitForSingleObject(guardian_information.hProcess, 5000);
    ::CloseHandle(guardian_information.hThread);
    ::CloseHandle(guardian_information.hProcess);
    if (error_code != nullptr) {
      *error_code = validation_error;
    }
    return false;
  }

  *process_information = guardian_information;
  if (error_code != nullptr) {
    *error_code = ERROR_SUCCESS;
  }
  return true;
}

bool StartGuardian(const std::wstring& launcher_path,
                   const std::wstring& launcher_directory,
                   DWORD child_process_id, DWORD child_thread_id,
                   HANDLE* guardian_process,
                   HANDLE* guardian_commit_event,
                   DWORD* error_code) {
  *guardian_process = nullptr;
  *guardian_commit_event = nullptr;
  const std::wstring event_suffix =
      std::to_wstring(child_process_id) + L"_" +
      std::to_wstring(::GetCurrentProcessId());
  const std::wstring ready_event_name =
      std::wstring(kGuardianReadyPrefix) + event_suffix;
  const std::wstring commit_event_name =
      std::wstring(kGuardianCommitPrefix) + event_suffix;
  HANDLE ready_event =
      ::CreateEventW(nullptr, TRUE, FALSE, ready_event_name.c_str());
  if (ready_event == nullptr) {
    if (error_code != nullptr) {
      *error_code = ::GetLastError();
    }
    return false;
  }
  HANDLE commit_event =
      ::CreateEventW(nullptr, TRUE, FALSE, commit_event_name.c_str());
  if (commit_event == nullptr) {
    const DWORD error = ::GetLastError();
    ::CloseHandle(ready_event);
    if (error_code != nullptr) {
      *error_code = error;
    }
    return false;
  }

  PROCESS_INFORMATION guardian_information = {};
  DWORD error = ERROR_SUCCESS;
  if (!CreateDetachedGuardianProcess(
          launcher_path, launcher_directory, child_process_id, child_thread_id,
          ready_event_name, commit_event_name, &guardian_information,
          &error)) {
    ::CloseHandle(ready_event);
    ::CloseHandle(commit_event);
    if (error_code != nullptr) {
      *error_code = error;
    }
    return false;
  }
  ::CloseHandle(guardian_information.hThread);

  HANDLE ready_handles[] = {ready_event, guardian_information.hProcess};
  const DWORD ready_wait =
      ::WaitForMultipleObjects(2, ready_handles, FALSE, 5000);
  ::CloseHandle(ready_event);
  if (ready_wait != WAIT_OBJECT_0) {
    if (ready_wait == WAIT_OBJECT_0 + 1) {
      if (!::GetExitCodeProcess(guardian_information.hProcess, &error)) {
        error = ::GetLastError();
      }
    } else {
      error = ready_wait == WAIT_TIMEOUT ? ERROR_TIMEOUT : ::GetLastError();
      ::TerminateProcess(guardian_information.hProcess, error);
      ::WaitForSingleObject(guardian_information.hProcess, INFINITE);
    }
    ::CloseHandle(guardian_information.hProcess);
    ::CloseHandle(commit_event);
    if (error_code != nullptr) {
      *error_code = error;
    }
    return false;
  }

  *guardian_process = guardian_information.hProcess;
  *guardian_commit_event = commit_event;
  if (error_code != nullptr) {
    *error_code = ERROR_SUCCESS;
  }
  return true;
}
constexpr DWORD kGuardianRestartAttempts = 5;
constexpr DWORD kGuardianRestartDelayMs = 100;
// ── Child process creation ──

bool CreateChildProcess(const std::wstring& child_path,
                        const std::wstring& working_directory,
                        std::wstring command_line, int show_command,
                        HANDLE process_job, bool* assigned_to_job,
                        PROCESS_INFORMATION* process_information,
                        DWORD* error_code) {
  STARTUPINFOW startup_info = {};
  startup_info.cb = sizeof(startup_info);
  startup_info.dwFlags = STARTF_USESHOWWINDOW;
  startup_info.wShowWindow = static_cast<WORD>(show_command);

  const bool has_standard_handles =
      HasUsableStandardHandle(STD_INPUT_HANDLE) ||
      HasUsableStandardHandle(STD_OUTPUT_HANDLE) ||
      HasUsableStandardHandle(STD_ERROR_HANDLE);
  if (has_standard_handles) {
    startup_info.dwFlags |= STARTF_USESTDHANDLES;
    startup_info.hStdInput = ::GetStdHandle(STD_INPUT_HANDLE);
    startup_info.hStdOutput = ::GetStdHandle(STD_OUTPUT_HANDLE);
    startup_info.hStdError = ::GetStdHandle(STD_ERROR_HANDLE);
  }

  const BOOL created = ::CreateProcessW(
      child_path.c_str(), command_line.data(), nullptr, nullptr,
      has_standard_handles ? TRUE : FALSE, CREATE_SUSPENDED, nullptr,
      working_directory.c_str(), &startup_info, process_information);
  if (assigned_to_job != nullptr) {
    *assigned_to_job = false;
  }
  if (created && process_job != nullptr) {
    if (::AssignProcessToJobObject(process_job,
                                   process_information->hProcess)) {
      if (assigned_to_job != nullptr) {
        *assigned_to_job = true;
      }
    } else {
      ::OutputDebugStringW(
          L"SSRVPN launcher could not assign the app process to its job.\n");
    }
  }
  if (error_code != nullptr) {
    *error_code = created ? ERROR_SUCCESS : ::GetLastError();
  }
  return created == TRUE;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE previous,
                      _In_ wchar_t* command_line, _In_ int show_command) {
  const std::wstring launcher_path = GetExecutablePath();
  const std::wstring launcher_directory = GetDirectoryName(launcher_path);
  const std::wstring child_directory = JoinPath(launcher_directory, L"bin");
  const std::wstring child_path = JoinPath(child_directory, kChildExeName);
  const std::wstring core_path = JoinPath(child_directory, L"mihomo.exe");

  DWORD guardian_child_process_id = 0;
  DWORD guardian_child_thread_id = 0;
  std::wstring guardian_ready_event_name;
  std::wstring guardian_commit_event_name;
  if (ParseGuardianArguments(&guardian_child_process_id,
                             &guardian_child_thread_id,
                             &guardian_ready_event_name,
                             &guardian_commit_event_name)) {
    return RunGuardian(child_path, guardian_child_process_id,
                       guardian_child_thread_id,
                       guardian_ready_event_name,
                       guardian_commit_event_name);
  }

  const bool elevated_tun_relaunch =
      HasExactCommandLineArgument(kElevatedTunRelaunchArgument);
  std::wstring elevated_tun_ready_event;
  ULONGLONG elevated_tun_handoff_deadline = 0;
  if (elevated_tun_relaunch) {
    const std::wstring expected_user_sid =
        CommandLineArgumentValue(kElevatedTunUserArgumentPrefix);
    const std::wstring current_user_sid = QueryCurrentUserSid();
    elevated_tun_ready_event =
        CommandLineArgumentValue(kElevatedTunReadyArgumentPrefix);
    if (!IsCurrentProcessElevated() || expected_user_sid.empty() ||
        current_user_sid.empty() ||
        ::_wcsicmp(expected_user_sid.c_str(), current_user_sid.c_str()) != 0 ||
        elevated_tun_ready_event.rfind(kElevatedTunReadyEventPrefix, 0) != 0) {
      ::OutputDebugStringW(
          L"SSRVPN refused a TUN elevation relaunch whose token or user SID "
          L"did not match the requesting user.\n");
      return ERROR_ACCESS_DENIED;
    }
    elevated_tun_handoff_deadline =
        ::GetTickCount64() + kElevationRelaunchTotalWaitMilliseconds;
  }

  if (::GetFileAttributesW(child_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    ShowError(L"SSRVPN",
              L"找不到 SSRVPN 主程序：\n\n" + child_path +
                  L"\n\n安装目录不完整，请重新运行 SSRVPN_Setup.exe 修复安装。"
    );
    return ERROR_FILE_NOT_FOUND;
  }

  HANDLE launcher_mutex =
      ::CreateMutexW(nullptr, FALSE, kLauncherMutexName);
  if (launcher_mutex == nullptr) {
    const DWORD error = ::GetLastError();
    ShowError(L"SSRVPN",
              L"无法建立 SSRVPN 启动保护：\n\n" +
                  GetLastErrorMessage(error));
    return static_cast<int>(error);
  }
  if (elevated_tun_relaunch) {
    HANDLE ready_event = ::OpenEventW(EVENT_MODIFY_STATE, FALSE,
                                      elevated_tun_ready_event.c_str());
    if (ready_event == nullptr) {
      const DWORD error = ::GetLastError();
      ::CloseHandle(launcher_mutex);
      return static_cast<int>(error);
    }
    const bool accepted = ::SetEvent(ready_event) != FALSE;
    const DWORD acceptance_error = accepted ? ERROR_SUCCESS : ::GetLastError();
    ::CloseHandle(ready_event);
    if (!accepted) {
      ::CloseHandle(launcher_mutex);
      return static_cast<int>(acceptance_error);
    }
  }
  const DWORD launcher_wait = ::WaitForSingleObject(
      launcher_mutex,
      elevated_tun_relaunch
          ? RemainingWaitMilliseconds(elevated_tun_handoff_deadline)
          : 0);
  if (launcher_wait == WAIT_TIMEOUT) {
    if (elevated_tun_relaunch) {
      ::CloseHandle(launcher_mutex);
      ShowError(
          L"SSRVPN TUN",
          L"旧的 SSRVPN 实例未能在安全时限内退出，因此管理员实例没有启动。\n\n"
          L"请确认旧实例已断开连接，再重新尝试 TUN 模式。");
      return ERROR_TIMEOUT;
    }
    bool existing_window_activated = false;
    HANDLE existing_process =
        OpenExistingChildProcess(child_path, true, nullptr, nullptr,
                                 &existing_window_activated);
    if (existing_process != nullptr && existing_window_activated) {
      ::CloseHandle(existing_process);
      ::CloseHandle(launcher_mutex);
      return EXIT_SUCCESS;
    }
    if (existing_process != nullptr) {
      ::CloseHandle(existing_process);
    }
    InstanceContentionAction action = SelectInstanceContentionAction(
        false, existing_process != nullptr,
        IsNamedMutexOwned(kProxyRecoveryMutexName),
        IsNamedMutexOwned(kAppMutexName),
        IsNamedMutexOwned(kGuardianMutexName));
    if (action == InstanceContentionAction::kContinueStartup) {
      action = InstanceContentionAction::kShowBackgroundCleanup;
    }
    ShowInstanceContentionNotice(action);
    ::CloseHandle(launcher_mutex);
    return ERROR_BUSY;
  }
  if (launcher_wait != WAIT_OBJECT_0 && launcher_wait != WAIT_ABANDONED) {
    const DWORD error = ::GetLastError();
    ::CloseHandle(launcher_mutex);
    ShowError(L"SSRVPN",
              L"无法取得 SSRVPN 启动保护：\n\n" +
                  GetLastErrorMessage(error));
    return static_cast<int>(error);
  }
  if (elevated_tun_relaunch) {
    const wchar_t* cleanup_mutexes[] = {
        kGuardianMutexName,
        kProxyRecoveryMutexName,
        kAppMutexName,
    };
    DWORD cleanup_wait_error = ERROR_SUCCESS;
    for (const wchar_t* cleanup_mutex : cleanup_mutexes) {
      const DWORD remaining =
          RemainingWaitMilliseconds(elevated_tun_handoff_deadline);
      if (!WaitForNamedMutexRelease(cleanup_mutex, remaining,
                                    &cleanup_wait_error)) {
        ::ReleaseMutex(launcher_mutex);
        ::CloseHandle(launcher_mutex);
        ShowError(
            L"SSRVPN TUN",
            L"旧的 SSRVPN 实例尚未完成安全清理，因此管理员实例没有启动。\n\n"
            L"请等待清理完成后重新尝试 TUN 模式；不要在任务管理器中强制结束"
            L"正在恢复网络的 SSRVPN 进程。");
        return static_cast<int>(
            cleanup_wait_error == ERROR_SUCCESS ? ERROR_TIMEOUT
                                                : cleanup_wait_error);
      }
    }
  }

  DWORD child_process_id = 0;
  DWORD child_process_open_error = ERROR_SUCCESS;
  bool current_window_activated = false;
  HANDLE child_process =
      OpenExistingChildProcess(child_path, true, &child_process_id,
                               &child_process_open_error,
                               &current_window_activated);
  if (child_process == nullptr &&
      child_process_open_error == ERROR_SUCCESS) {
    child_process = FindChildProcessByPath(
        child_path, kChildExeName, &child_process_id,
        &child_process_open_error);
  }
  if (child_process == nullptr &&
      child_process_open_error != ERROR_SUCCESS) {
    ::ReleaseMutex(launcher_mutex);
    ::CloseHandle(launcher_mutex);
    ShowError(L"SSRVPN",
              L"无法安全接管已有 SSRVPN 进程：\n\n" +
                  GetLastErrorMessage(child_process_open_error));
    return static_cast<int>(child_process_open_error);
  }
  const bool guardian_already_running =
      IsNamedMutexOwned(kGuardianMutexName);
  const InstanceContentionAction contention_action =
      SelectInstanceContentionAction(
          current_window_activated, child_process != nullptr,
          IsNamedMutexOwned(kProxyRecoveryMutexName),
          IsNamedMutexOwned(kAppMutexName), guardian_already_running);
  if (contention_action != InstanceContentionAction::kContinueStartup) {
    if (child_process != nullptr) {
      ::CloseHandle(child_process);
    }
    ::ReleaseMutex(launcher_mutex);
    ::CloseHandle(launcher_mutex);
    if (contention_action ==
        InstanceContentionAction::kActivateCurrentInstance) {
      return EXIT_SUCCESS;
    }
    ShowInstanceContentionNotice(contention_action);
    return ERROR_BUSY;
  }

  HANDLE process_job = CreateProcessJob();
  const DWORD process_job_error =
      process_job == nullptr ? ::GetLastError() : ERROR_SUCCESS;
  bool assigned_to_job = false;
  HANDLE child_thread = nullptr;
  DWORD child_thread_id = 0;
  const bool attached_to_existing = child_process != nullptr;
  DWORD error = process_job_error;
  if (child_process == nullptr) {
    PROCESS_INFORMATION process_information = {};
    const std::wstring child_command_line = BuildChildCommandLine(child_path);
    if (!CreateChildProcess(child_path, child_directory, child_command_line,
                            show_command, process_job, &assigned_to_job,
                            &process_information, &error)) {
      if (process_job != nullptr) {
        ::CloseHandle(process_job);
      }
      ::ReleaseMutex(launcher_mutex);
      ::CloseHandle(launcher_mutex);
      ShowError(L"SSRVPN",
                L"无法启动 SSRVPN 主程序：\n\n" +
                    GetLastErrorMessage(error));
      return static_cast<int>(error);
    }
    child_process = process_information.hProcess;
    child_thread = process_information.hThread;
    child_thread_id = process_information.dwThreadId;
    child_process_id = process_information.dwProcessId;
  }
  if (attached_to_existing &&
      !AdoptExistingChildProcessTree(process_job, child_process, core_path,
                                     &error)) {
    if (process_job != nullptr) {
      ::CloseHandle(process_job);
    }
    ::CloseHandle(child_process);
    ::ReleaseMutex(launcher_mutex);
    ::CloseHandle(launcher_mutex);
    ShowError(
        L"SSRVPN",
        L"检测到已运行的 SSRVPN，但无法将它安全纳入崩溃保护。\n\n" +
            GetLastErrorMessage(error) +
            L"\n\n现有进程未被终止。请先从应用内正常退出，再重新启动 SSRVPN。");
    return static_cast<int>(error == ERROR_SUCCESS ? ERROR_ACCESS_DENIED
                                                    : error);
  }
  if (attached_to_existing) {
    assigned_to_job = true;
  }

  HANDLE guardian_process = nullptr;
  HANDLE guardian_commit_event = nullptr;
  bool guardian_ready = false;
  if (process_job != nullptr) {
    guardian_ready =
        StartGuardian(launcher_path, launcher_directory, child_process_id,
                      child_thread_id, &guardian_process,
                      &guardian_commit_event, &error);
  } else {
    error = process_job_error;
  }
  if (guardian_ready &&
      ::WaitForSingleObject(guardian_process, 0) != WAIT_TIMEOUT) {
    if (!::GetExitCodeProcess(guardian_process, &error)) {
      error = ::GetLastError();
    }
    ::CloseHandle(guardian_process);
    guardian_process = nullptr;
    ::CloseHandle(guardian_commit_event);
    guardian_commit_event = nullptr;
    guardian_ready = false;
  }
  const bool initial_guardian_failed = !guardian_ready;
  std::wstring startup_failure_message =
      child_thread != nullptr
          ? L"SSRVPN guardian is not ready. To avoid running without crash "
            L"protection, the app was not started. Windows system proxy "
            L"recovery is being completed before exit."
          : L"SSRVPN guardian could not protect the existing app. Windows "
            L"system proxy recovery and safe process cleanup are in progress.";
  HANDLE guardian_failure_notice = nullptr;
  if (!guardian_ready) {
    ::OutputDebugStringW(
        (L"SSRVPN independent guardian unavailable: " +
         GetLastErrorMessage(error) + L"\n")
            .c_str());
    guardian_failure_notice =
        ShowErrorAsync(L"SSRVPN guardian not ready", startup_failure_message);
  }

  bool commit_failed = false;
  if (guardian_ready && guardian_commit_event != nullptr) {
    if (!::SetEvent(guardian_commit_event)) {
      const DWORD commit_error = ::GetLastError();
      ::OutputDebugStringW(
          (L"SSRVPN guardian commit failed: " +
           GetLastErrorMessage(commit_error) + L"\n")
              .c_str());
      commit_failed = true;
      guardian_ready = false;
      if (guardian_process != nullptr) {
        ::TerminateProcess(guardian_process, commit_error);
        ::WaitForSingleObject(guardian_process, 5000);
        ::CloseHandle(guardian_process);
        guardian_process = nullptr;
      }
      startup_failure_message =
          L"SSRVPN guardian startup handshake could not be committed. The "
          L"app will not continue without protection; Windows system proxy "
          L"recovery and process cleanup are in progress.";
      if (guardian_failure_notice == nullptr) {
        guardian_failure_notice =
            ShowErrorAsync(L"SSRVPN guardian handshake failed",
                           startup_failure_message);
      }
    }
    ::CloseHandle(guardian_commit_event);
    guardian_commit_event = nullptr;
  }

  bool post_commit_guardian_failed = false;
  if (guardian_ready &&
      ::WaitForSingleObject(guardian_process, 0) != WAIT_TIMEOUT) {
    post_commit_guardian_failed = true;
    if (!::GetExitCodeProcess(guardian_process, &error)) {
      error = ::GetLastError();
    }
    ::CloseHandle(guardian_process);
    guardian_process = nullptr;
    guardian_ready = false;
    startup_failure_message =
        L"SSRVPN guardian exited after the startup commit. The suspended app "
        L"was not resumed; Windows system proxy recovery and process cleanup "
        L"are in progress.";
    if (guardian_failure_notice == nullptr) {
      guardian_failure_notice =
          ShowErrorAsync(L"SSRVPN guardian exited during startup",
                         startup_failure_message);
    }
  }

  const DWORD previous_suspend_count =
      guardian_ready && child_thread != nullptr
          ? ::ResumeThread(child_thread)
          : 1;
  bool resume_failed = false;
  if (guardian_ready && child_thread != nullptr &&
      previous_suspend_count > 1) {
    resume_failed = true;
    const DWORD resume_error =
        previous_suspend_count == static_cast<DWORD>(-1)
            ? ::GetLastError()
            : ERROR_INVALID_STATE;
    if (guardian_process != nullptr) {
      ::TerminateProcess(guardian_process, resume_error);
      ::WaitForSingleObject(guardian_process, 5000);
      ::CloseHandle(guardian_process);
      guardian_process = nullptr;
    }
    guardian_ready = false;
    startup_failure_message =
        L"SSRVPN guardian was ready, but the suspended app thread could not "
        L"be resumed safely. The app will not continue; Windows system proxy "
        L"recovery and process cleanup are in progress.";
    if (guardian_failure_notice == nullptr) {
      guardian_failure_notice =
          ShowErrorAsync(L"SSRVPN app was not started safely",
                         startup_failure_message);
    }
  }

  const bool startup_protection_failed =
      initial_guardian_failed || commit_failed ||
      post_commit_guardian_failed || resume_failed;
  bool guardian_restart_pending = startup_protection_failed;
  bool fail_closed_cleanup_pending = startup_protection_failed;
  bool safe_disconnect_visible = false;
  while (true) {
    if (guardian_process != nullptr) {
      HANDLE supervision_handles[] = {child_process, guardian_process};
      const DWORD supervision_wait =
          ::WaitForMultipleObjects(2, supervision_handles, FALSE, INFINITE);
      if (supervision_wait == WAIT_OBJECT_0) {
        break;
      }
      if (supervision_wait == WAIT_OBJECT_0 + 1) {
        ::CloseHandle(guardian_process);
        guardian_process = nullptr;
        if (::WaitForSingleObject(child_process, 0) == WAIT_OBJECT_0) {
          break;
        }
        guardian_restart_pending = true;
        ::OutputDebugStringW(
            L"SSRVPN independent guardian exited before the app; "
            L"restarting protection.\n");
        continue;
      }

      const DWORD supervision_error = ::GetLastError();
      ::OutputDebugStringW(
          (L"SSRVPN guardian supervision failed: " +
           GetLastErrorMessage(supervision_error) + L"\n")
              .c_str());
      ::CloseHandle(guardian_process);
      guardian_process = nullptr;
      guardian_restart_pending = true;
      continue;
    }

    if (!guardian_restart_pending) {
      ::WaitForSingleObject(child_process, INFINITE);
      break;
    }
    if (!fail_closed_cleanup_pending) {
      HANDLE replacement_commit_event = nullptr;
      if (process_job != nullptr &&
          RetryGuardianStart(kGuardianRestartAttempts,
              kGuardianRestartDelayMs, [&]() {
                return StartGuardian(
                    launcher_path, launcher_directory, child_process_id, 0,
                    &guardian_process, &replacement_commit_event, &error);
              })) {
        if (::SetEvent(replacement_commit_event)) {
          ::CloseHandle(replacement_commit_event);
          continue;
        }
        error = ::GetLastError();
        ::OutputDebugStringW(
            (L"SSRVPN replacement guardian commit failed: " +
             GetLastErrorMessage(error) + L"\n")
                .c_str());
        ::CloseHandle(replacement_commit_event);
        ::TerminateProcess(guardian_process, error);
        ::WaitForSingleObject(guardian_process, 5000);
        ::CloseHandle(guardian_process);
        guardian_process = nullptr;
      }

      ::OutputDebugStringW(
          (L"SSRVPN could not restart the independent guardian: " +
           GetLastErrorMessage(error) + L"\n")
              .c_str());
      fail_closed_cleanup_pending = true;
    }
    const DWORD cleanup_error = RestoreAndTerminateGuardedProcess(
        child_process, &process_job, !safe_disconnect_visible);
    if (cleanup_error != ERROR_BUSY) {
      safe_disconnect_visible = true;
    }
    if (::WaitForSingleObject(child_process, 0) == WAIT_OBJECT_0) {
      if (cleanup_error == ERROR_SUCCESS) {
        break;
      }
      ::Sleep(1000);
      continue;
    }
    ::OutputDebugStringW(
        (L"SSRVPN fail-closed process cleanup failed: " +
         GetLastErrorMessage(cleanup_error) + L"\n")
            .c_str());
    const DWORD child_retry_wait =
        ::WaitForSingleObject(child_process, 1000);
    if (child_retry_wait == WAIT_OBJECT_0) {
      ::Sleep(1000);
      continue;
    }
    if (child_retry_wait == WAIT_FAILED) {
      ::Sleep(1000);
    }
  }

  DWORD exit_code = EXIT_FAILURE;
  if (!::GetExitCodeProcess(child_process, &exit_code)) {
    exit_code = ::GetLastError();
  }
  if (child_thread != nullptr) {
    ::CloseHandle(child_thread);
  }
  ::CloseHandle(child_process);

  if (guardian_process != nullptr) {
    const DWORD guardian_wait =
        ::WaitForSingleObject(guardian_process, 5000);
    if (guardian_wait == WAIT_TIMEOUT) {
      ::OutputDebugStringW(
          L"SSRVPN guardian is still completing fail-closed cleanup; "
          L"the launcher will leave it running.\n");
    }
    ::CloseHandle(guardian_process);
  }

  if (!ChildExitRequiresProxyPreservation(exit_code) &&
      RestoreProxyForProcessCleanup()) {
    if (process_job != nullptr && (assigned_to_job || attached_to_existing)) {
      ::TerminateJobObject(process_job, EXIT_FAILURE);
    }
  }
  exit_code = ResolveChildExitCode(
      exit_code, IsNamedMutexOwned(kProxyRecoveryMutexName),
      IsNamedMutexOwned(kAppMutexName), IsNamedMutexOwned(kGuardianMutexName));
  if (process_job != nullptr) {
    ::CloseHandle(process_job);
  }
  if (startup_protection_failed) {
    if (guardian_failure_notice != nullptr) {
      ::WaitForSingleObject(guardian_failure_notice, 5000);
      ::CloseHandle(guardian_failure_notice);
    } else {
      ShowError(L"SSRVPN guardian not ready", startup_failure_message);
    }
  }
  ::ReleaseMutex(launcher_mutex);
  ::CloseHandle(launcher_mutex);
  return static_cast<int>(exit_code);
}
