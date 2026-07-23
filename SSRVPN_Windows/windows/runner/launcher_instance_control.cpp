#include "launcher_instance_control.h"

#include <windows.h>
#include <tlhelp32.h>

#include <cwchar>
#include <string>
#include <vector>

namespace {

constexpr wchar_t kCoreExeName[] = L"mihomo.exe";
constexpr int kAdoptionSnapshotPasses = 3;
constexpr DWORD kAdoptionSnapshotDelayMs = 10;

struct ProcessTokenSecurity {
  TOKEN_ELEVATION_TYPE elevation_type = TokenElevationTypeDefault;
  DWORD integrity_rid = 0;
  std::vector<unsigned char> user_sid;
};

bool ReadProcessTokenSecurity(HANDLE process, ProcessTokenSecurity* security,
                              DWORD* error_code) {
  HANDLE token = nullptr;
  if (!::OpenProcessToken(process, TOKEN_QUERY, &token)) {
    if (error_code != nullptr) *error_code = ::GetLastError();
    return false;
  }

  DWORD bytes = 0;
  if (!::GetTokenInformation(token, TokenElevationType,
                             &security->elevation_type,
                             sizeof(security->elevation_type), &bytes)) {
    const DWORD error = ::GetLastError();
    ::CloseHandle(token);
    if (error_code != nullptr) *error_code = error;
    return false;
  }
  ::GetTokenInformation(token, TokenIntegrityLevel, nullptr, 0, &bytes);
  std::vector<unsigned char> buffer(bytes);
  if (bytes == 0 ||
      !::GetTokenInformation(token, TokenIntegrityLevel, buffer.data(), bytes,
                             &bytes)) {
    const DWORD error = bytes == 0 ? ERROR_INVALID_TOKEN : ::GetLastError();
    ::CloseHandle(token);
    if (error_code != nullptr) *error_code = error;
    return false;
  }

  const auto* label =
      reinterpret_cast<const TOKEN_MANDATORY_LABEL*>(buffer.data());
  if (!::IsValidSid(label->Label.Sid)) {
    ::CloseHandle(token);
    if (error_code != nullptr) *error_code = ERROR_INVALID_SID;
    return false;
  }
  const UCHAR subauthority_count =
      *::GetSidSubAuthorityCount(label->Label.Sid);
  if (subauthority_count == 0) {
    ::CloseHandle(token);
    if (error_code != nullptr) *error_code = ERROR_INVALID_SID;
    return false;
  }
  security->integrity_rid =
      *::GetSidSubAuthority(label->Label.Sid, subauthority_count - 1);

  bytes = 0;
  ::GetTokenInformation(token, TokenUser, nullptr, 0, &bytes);
  std::vector<unsigned char> user_buffer(bytes);
  if (bytes == 0 ||
      !::GetTokenInformation(token, TokenUser, user_buffer.data(), bytes,
                             &bytes)) {
    const DWORD error = bytes == 0 ? ERROR_INVALID_TOKEN : ::GetLastError();
    ::CloseHandle(token);
    if (error_code != nullptr) *error_code = error;
    return false;
  }
  const auto* user = reinterpret_cast<const TOKEN_USER*>(user_buffer.data());
  if (!::IsValidSid(user->User.Sid)) {
    ::CloseHandle(token);
    if (error_code != nullptr) *error_code = ERROR_INVALID_SID;
    return false;
  }
  const DWORD sid_bytes = ::GetLengthSid(user->User.Sid);
  security->user_sid.resize(sid_bytes);
  if (!::CopySid(sid_bytes, security->user_sid.data(), user->User.Sid)) {
    const DWORD error = ::GetLastError();
    ::CloseHandle(token);
    if (error_code != nullptr) *error_code = error;
    return false;
  }
  ::CloseHandle(token);
  if (error_code != nullptr) *error_code = ERROR_SUCCESS;
  return true;
}

bool CaptureProcessEntries(std::vector<PROCESSENTRY32W>* entries,
                           FILETIME* snapshot_completion_time,
                           DWORD* error_code) {
  HANDLE snapshot = ::CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) {
    if (error_code != nullptr) *error_code = ::GetLastError();
    return false;
  }

  PROCESSENTRY32W entry = {};
  entry.dwSize = sizeof(entry);
  if (!::Process32FirstW(snapshot, &entry)) {
    const DWORD error = ::GetLastError();
    ::CloseHandle(snapshot);
    if (error_code != nullptr) *error_code = error;
    return false;
  }
  do {
    entries->push_back(entry);
    entry.dwSize = sizeof(entry);
  } while (::Process32NextW(snapshot, &entry));
  const DWORD enumeration_error = ::GetLastError();
  // Process creation times and this timestamp share the FILETIME epoch. The
  // precise clock keeps the upper-bound check below from rejecting a process
  // that was already present in the completed snapshot.
  ::GetSystemTimePreciseAsFileTime(snapshot_completion_time);
  ::CloseHandle(snapshot);
  if (enumeration_error != ERROR_NO_MORE_FILES) {
    if (error_code != nullptr) *error_code = enumeration_error;
    return false;
  }
  if (error_code != nullptr) *error_code = ERROR_SUCCESS;
  return true;
}

bool SnapshotConfirmsDirectChild(
    DWORD candidate_id, DWORD parent_id,
    const std::vector<PROCESSENTRY32W>& entries) {
  for (const PROCESSENTRY32W& entry : entries) {
    if (entry.th32ProcessID == candidate_id) {
      return entry.th32ParentProcessID == parent_id &&
             _wcsicmp(entry.szExeFile, kCoreExeName) == 0;
    }
  }
  return false;
}

bool ReadProcessCreationTime(HANDLE process, FILETIME* creation_time,
                             DWORD* error_code) {
  FILETIME exit_time = {};
  FILETIME kernel_time = {};
  FILETIME user_time = {};
  if (!::GetProcessTimes(process, creation_time, &exit_time, &kernel_time,
                         &user_time)) {
    if (error_code != nullptr) *error_code = ::GetLastError();
    return false;
  }
  if (error_code != nullptr) *error_code = ERROR_SUCCESS;
  return true;
}

bool EnsureProcessInJob(HANDLE process_job, HANDLE process,
                        bool exited_is_safe, DWORD* error_code) {
  BOOL belongs_to_job = FALSE;
  if (!::IsProcessInJob(process, process_job, &belongs_to_job)) {
    const DWORD query_error = ::GetLastError();
    if (exited_is_safe &&
        ::WaitForSingleObject(process, 0) == WAIT_OBJECT_0) {
      return true;
    }
    if (error_code != nullptr) *error_code = query_error;
    return false;
  }
  if (!belongs_to_job && !::AssignProcessToJobObject(process_job, process)) {
    const DWORD assignment_error = ::GetLastError();
    if (exited_is_safe &&
        ::WaitForSingleObject(process, 0) == WAIT_OBJECT_0) {
      return true;
    }
    if (error_code != nullptr) *error_code = assignment_error;
    return false;
  }

  belongs_to_job = FALSE;
  if (!::IsProcessInJob(process, process_job, &belongs_to_job)) {
    const DWORD query_error = ::GetLastError();
    if (exited_is_safe &&
        ::WaitForSingleObject(process, 0) == WAIT_OBJECT_0) {
      return true;
    }
    if (error_code != nullptr) *error_code = query_error;
    return false;
  }
  if (!belongs_to_job) {
    if (error_code != nullptr) *error_code = ERROR_INVALID_OWNER;
    return false;
  }
  if (error_code != nullptr) *error_code = ERROR_SUCCESS;
  return true;
}

bool AdoptExpectedDirectCoreChildren(
    HANDLE process_job, HANDLE child_process, DWORD child_process_id,
    DWORD child_session_id, const FILETIME& child_creation_time,
    const std::wstring& expected_core_path, DWORD* error_code) {
  std::vector<PROCESSENTRY32W> entries;
  FILETIME snapshot_completion_time = {};
  if (!CaptureProcessEntries(&entries, &snapshot_completion_time,
                             error_code)) {
    return false;
  }

  for (const PROCESSENTRY32W& entry : entries) {
    if (_wcsicmp(entry.szExeFile, kCoreExeName) != 0 ||
        entry.th32ParentProcessID != child_process_id) {
      continue;
    }

    // AssignProcessToJobObject requires both PROCESS_SET_QUOTA and
    // PROCESS_TERMINATE even though adoption does not terminate the process.
    HANDLE core_process = ::OpenProcess(
        SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SET_QUOTA |
            PROCESS_TERMINATE,
        FALSE, entry.th32ProcessID);
    if (core_process == nullptr) {
      const DWORD open_error = ::GetLastError();
      if (open_error == ERROR_INVALID_PARAMETER) {
        continue;
      }
      if (error_code != nullptr) *error_code = open_error;
      return false;
    }
    if (::WaitForSingleObject(core_process, 0) == WAIT_OBJECT_0) {
      ::CloseHandle(core_process);
      continue;
    }

    DWORD validation_error = ERROR_SUCCESS;
    if (!ProcessImageMatches(core_process, expected_core_path)) {
      validation_error = ERROR_INVALID_OWNER;
      ::CloseHandle(core_process);
      if (error_code != nullptr) *error_code = validation_error;
      return false;
    }
    DWORD core_session_id = 0;
    if (!::ProcessIdToSessionId(entry.th32ProcessID, &core_session_id)) {
      validation_error = ::GetLastError();
      ::CloseHandle(core_process);
      if (error_code != nullptr) *error_code = validation_error;
      return false;
    }
    if (core_session_id != child_session_id ||
        !ProcessTokensHaveSecurityParity(child_process, core_process,
                                         &validation_error)) {
      if (validation_error == ERROR_SUCCESS) {
        validation_error = ERROR_ACCESS_DENIED;
      }
      ::CloseHandle(core_process);
      if (error_code != nullptr) *error_code = validation_error;
      return false;
    }
    FILETIME core_creation_time = {};
    if (!ReadProcessCreationTime(core_process, &core_creation_time,
                                 &validation_error) ||
        ::CompareFileTime(&core_creation_time, &child_creation_time) < 0 ||
        ::CompareFileTime(&core_creation_time, &snapshot_completion_time) >
            0) {
      if (validation_error == ERROR_SUCCESS) {
        validation_error = ERROR_INVALID_OWNER;
      }
      ::CloseHandle(core_process);
      if (error_code != nullptr) *error_code = validation_error;
      return false;
    }

    // The first snapshot supplied the candidate PID and parent PID. Refresh it
    // while the process handle is held, then confirm that the still-running
    // process is the direct mihomo child started by the Flutter app. If the
    // original PID exited and was reused after the first snapshot, either the
    // creation-time upper bound or this handle-bound refresh rejects it before
    // the irreversible job assignment.
    std::vector<PROCESSENTRY32W> refreshed_entries;
    FILETIME refreshed_snapshot_completion_time = {};
    if (!CaptureProcessEntries(&refreshed_entries,
                               &refreshed_snapshot_completion_time,
                               &validation_error)) {
      ::CloseHandle(core_process);
      if (error_code != nullptr) *error_code = validation_error;
      return false;
    }
    if (::WaitForSingleObject(child_process, 0) != WAIT_TIMEOUT) {
      ::CloseHandle(core_process);
      if (error_code != nullptr) *error_code = ERROR_PROCESS_ABORTED;
      return false;
    }
    const DWORD core_wait = ::WaitForSingleObject(core_process, 0);
    if (core_wait == WAIT_OBJECT_0) {
      ::CloseHandle(core_process);
      continue;
    }
    if (core_wait != WAIT_TIMEOUT ||
        !SnapshotConfirmsDirectChild(entry.th32ProcessID, child_process_id,
                                     refreshed_entries) ||
        ::CompareFileTime(&core_creation_time,
                          &refreshed_snapshot_completion_time) > 0) {
      if (core_wait != WAIT_TIMEOUT) {
        validation_error = ::GetLastError();
        if (validation_error == ERROR_SUCCESS) {
          validation_error = ERROR_INVALID_HANDLE;
        }
      } else {
        validation_error = ERROR_INVALID_OWNER;
      }
      ::CloseHandle(core_process);
      if (error_code != nullptr) *error_code = validation_error;
      return false;
    }

    const bool adopted =
        EnsureProcessInJob(process_job, core_process, true, error_code);
    ::CloseHandle(core_process);
    if (!adopted) {
      return false;
    }
  }
  if (error_code != nullptr) *error_code = ERROR_SUCCESS;
  return true;
}

}  // namespace

bool ProcessImageMatches(HANDLE process, const std::wstring& expected_path) {
  std::vector<wchar_t> path(32768);
  DWORD path_length = static_cast<DWORD>(path.size());
  if (!::QueryFullProcessImageNameW(process, 0, path.data(), &path_length)) {
    return false;
  }
  return ::CompareStringOrdinal(
             path.data(), static_cast<int>(path_length), expected_path.c_str(),
             static_cast<int>(expected_path.size()), TRUE) == CSTR_EQUAL;
}

bool ProcessTokensHaveSecurityParity(HANDLE first_process,
                                     HANDLE second_process,
                                     DWORD* error_code) {
  ProcessTokenSecurity first;
  ProcessTokenSecurity second;
  if (!ReadProcessTokenSecurity(first_process, &first, error_code) ||
      !ReadProcessTokenSecurity(second_process, &second, error_code)) {
    return false;
  }
  if (first.elevation_type != second.elevation_type ||
      first.integrity_rid != second.integrity_rid ||
      first.user_sid.empty() || second.user_sid.empty() ||
      !::EqualSid(first.user_sid.data(), second.user_sid.data())) {
    if (error_code != nullptr) *error_code = ERROR_ACCESS_DENIED;
    return false;
  }
  if (error_code != nullptr) *error_code = ERROR_SUCCESS;
  return true;
}

HANDLE OpenExistingChildProcess(const std::wstring& child_path,
                                bool activate_window, DWORD* process_id,
                                DWORD* open_error, bool* window_activated) {
  if (window_activated != nullptr) {
    *window_activated = false;
  }
  constexpr const wchar_t* kWindowTitles[] = {L"SSRVPN",
                                               L"ssrvpn_windows"};
  for (const wchar_t* title : kWindowTitles) {
    HWND window = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", title);
    if (window == nullptr) {
      continue;
    }

    DWORD candidate_id = 0;
    ::GetWindowThreadProcessId(window, &candidate_id);
    if (candidate_id == 0) {
      continue;
    }
    HANDLE process = ::OpenProcess(
        SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SET_QUOTA |
            PROCESS_TERMINATE,
        FALSE, candidate_id);
    if (process == nullptr) {
      const DWORD terminate_error = ::GetLastError();
      HANDLE query_process = ::OpenProcess(
          SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
          candidate_id);
      if (query_process == nullptr) {
        continue;
      }
      const bool matches = ProcessImageMatches(query_process, child_path);
      ::CloseHandle(query_process);
      if (matches) {
        if (open_error != nullptr) {
          *open_error = terminate_error == ERROR_SUCCESS
                            ? ERROR_ACCESS_DENIED
                            : terminate_error;
        }
        return nullptr;
      }
      continue;
    }
    if (!ProcessImageMatches(process, child_path)) {
      ::CloseHandle(process);
      continue;
    }

    if (activate_window && !::IsHungAppWindow(window)) {
      ::ShowWindow(window, SW_SHOW);
      ::ShowWindow(window, SW_RESTORE);
      ::SetForegroundWindow(window);
      if (window_activated != nullptr) {
        *window_activated = true;
      }
    }
    if (process_id != nullptr) {
      *process_id = candidate_id;
    }
    return process;
  }
  return nullptr;
}

HANDLE FindChildProcessByPath(const std::wstring& child_path,
                              const wchar_t* child_exe_name,
                              DWORD* process_id, DWORD* open_error) {
  HANDLE snapshot = ::CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) {
    if (open_error != nullptr) {
      *open_error = ::GetLastError();
    }
    return nullptr;
  }
  DWORD current_session_id = 0;
  if (!::ProcessIdToSessionId(::GetCurrentProcessId(), &current_session_id)) {
    const DWORD error = ::GetLastError();
    ::CloseHandle(snapshot);
    if (open_error != nullptr) {
      *open_error = error;
    }
    return nullptr;
  }
  PROCESSENTRY32W entry = {};
  entry.dwSize = sizeof(entry);
  BOOL has_entry = ::Process32FirstW(snapshot, &entry);
  while (has_entry) {
    if (_wcsicmp(entry.szExeFile, child_exe_name) == 0) {
      DWORD candidate_session_id = 0;
      if (!::ProcessIdToSessionId(entry.th32ProcessID,
                                  &candidate_session_id)) {
        has_entry = ::Process32NextW(snapshot, &entry);
        continue;
      }
      if (candidate_session_id == current_session_id) {
        HANDLE process = ::OpenProcess(
            SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION |
                PROCESS_SET_QUOTA | PROCESS_TERMINATE,
            FALSE, entry.th32ProcessID);
        if (process != nullptr) {
          if (ProcessImageMatches(process, child_path)) {
            ::CloseHandle(snapshot);
            if (process_id != nullptr) {
              *process_id = entry.th32ProcessID;
            }
            return process;
          }
          ::CloseHandle(process);
        } else {
          const DWORD terminate_error = ::GetLastError();
          HANDLE query_process = ::OpenProcess(
              SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
              entry.th32ProcessID);
          if (query_process != nullptr) {
            const bool matches =
                ProcessImageMatches(query_process, child_path);
            ::CloseHandle(query_process);
            if (matches) {
              ::CloseHandle(snapshot);
              if (open_error != nullptr) {
                *open_error = terminate_error == ERROR_SUCCESS
                                  ? ERROR_ACCESS_DENIED
                                  : terminate_error;
              }
              return nullptr;
            }
          }
        }
      }
    }
    has_entry = ::Process32NextW(snapshot, &entry);
  }
  ::CloseHandle(snapshot);
  return nullptr;
}

bool AdoptExistingChildProcessTree(HANDLE process_job, HANDLE child_process,
                                   const std::wstring& expected_core_path,
                                   DWORD* error_code) {
  if (process_job == nullptr || child_process == nullptr ||
      expected_core_path.empty()) {
    if (error_code != nullptr) *error_code = ERROR_INVALID_PARAMETER;
    return false;
  }

  DWORD security_error = ERROR_SUCCESS;
  if (!ProcessTokensHaveSecurityParity(::GetCurrentProcess(), child_process,
                                       &security_error)) {
    if (error_code != nullptr) *error_code = security_error;
    return false;
  }

  const DWORD child_process_id = ::GetProcessId(child_process);
  if (child_process_id == 0) {
    const DWORD process_error = ::GetLastError();
    if (error_code != nullptr) {
      *error_code = process_error == ERROR_SUCCESS ? ERROR_INVALID_HANDLE
                                                   : process_error;
    }
    return false;
  }
  DWORD child_session_id = 0;
  if (!::ProcessIdToSessionId(child_process_id, &child_session_id)) {
    if (error_code != nullptr) *error_code = ::GetLastError();
    return false;
  }
  DWORD launcher_session_id = 0;
  if (!::ProcessIdToSessionId(::GetCurrentProcessId(),
                              &launcher_session_id)) {
    if (error_code != nullptr) *error_code = ::GetLastError();
    return false;
  }
  if (launcher_session_id != child_session_id) {
    if (error_code != nullptr) *error_code = ERROR_ACCESS_DENIED;
    return false;
  }
  FILETIME child_creation_time = {};
  if (!ReadProcessCreationTime(child_process, &child_creation_time,
                               error_code)) {
    return false;
  }

  // Assign the app first. Any core started after this point inherits the job;
  // the bounded snapshots below only need to adopt cores that already exist.
  if (!EnsureProcessInJob(process_job, child_process, false, error_code)) {
    return false;
  }
  for (int pass = 0; pass < kAdoptionSnapshotPasses; ++pass) {
    if (::WaitForSingleObject(child_process, 0) != WAIT_TIMEOUT) {
      if (error_code != nullptr) *error_code = ERROR_PROCESS_ABORTED;
      return false;
    }
    if (!AdoptExpectedDirectCoreChildren(
            process_job, child_process, child_process_id, child_session_id,
            child_creation_time, expected_core_path, error_code)) {
      return false;
    }
    if (pass + 1 < kAdoptionSnapshotPasses) {
      ::Sleep(kAdoptionSnapshotDelayMs);
    }
  }

  if (error_code != nullptr) *error_code = ERROR_SUCCESS;
  return true;
}

bool IsNamedMutexOwned(const wchar_t* name) {
  HANDLE mutex =
      ::OpenMutexW(SYNCHRONIZE | MUTEX_MODIFY_STATE, FALSE, name);
  if (mutex == nullptr) {
    return false;
  }
  const DWORD wait_result = ::WaitForSingleObject(mutex, 0);
  const bool owned = wait_result == WAIT_TIMEOUT || wait_result == WAIT_FAILED;
  if (wait_result == WAIT_OBJECT_0 || wait_result == WAIT_ABANDONED) {
    ::ReleaseMutex(mutex);
  }
  ::CloseHandle(mutex);
  return owned;
}

bool WaitForNamedMutexRelease(const wchar_t* name, DWORD timeout_ms,
                              DWORD* error_code) {
  HANDLE mutex =
      ::OpenMutexW(SYNCHRONIZE | MUTEX_MODIFY_STATE, FALSE, name);
  if (mutex == nullptr) {
    const DWORD error = ::GetLastError();
    if (error == ERROR_FILE_NOT_FOUND) {
      if (error_code != nullptr) *error_code = ERROR_SUCCESS;
      return true;
    }
    if (error_code != nullptr) *error_code = error;
    return false;
  }

  const DWORD wait_result = ::WaitForSingleObject(mutex, timeout_ms);
  if (wait_result == WAIT_OBJECT_0 || wait_result == WAIT_ABANDONED) {
    const bool released = ::ReleaseMutex(mutex) != FALSE;
    const DWORD release_error = released ? ERROR_SUCCESS : ::GetLastError();
    ::CloseHandle(mutex);
    if (error_code != nullptr) *error_code = release_error;
    return released;
  }

  const DWORD wait_error =
      wait_result == WAIT_TIMEOUT ? ERROR_TIMEOUT : ::GetLastError();
  ::CloseHandle(mutex);
  if (error_code != nullptr) *error_code = wait_error;
  return false;
}

void ShowInstanceContentionNotice(InstanceContentionAction action) {
  std::wstring message;
  switch (action) {
    case InstanceContentionAction::kShowProxyRecovery:
      message =
          L"SSRVPN 正在恢复 Windows 系统代理，暂时无法打开窗口。\n\n"
          L"请等待几秒后重试。若长时间没有恢复，请重启 Windows；"
          L"请勿强制结束正在恢复代理的进程。";
      break;
    case InstanceContentionAction::kShowConflictingCopy:
      message =
          L"另一个 SSRVPN 副本正在运行，当前安装版无法安全启动。\n\n"
          L"请先关闭其他 SSRVPN 窗口；如仍无窗口，请在任务管理器中"
          L"结束旧副本的 SSRVPN 进程，然后重试。";
      break;
    default:
      message =
          L"SSRVPN 正在启动或执行安全清理，窗口暂时不可用。\n\n"
          L"请等待几秒后重试。若提示持续出现，请在任务管理器中确认"
          L"没有旧的 SSRVPN 副本，或重启 Windows。";
      break;
  }
  ::MessageBoxW(nullptr, message.c_str(), L"SSRVPN 暂时无法打开",
                MB_OK | MB_ICONWARNING);
}

bool ChildExitRequiresProxyPreservation(DWORD exit_code) {
  return exit_code == ERROR_ALREADY_EXISTS || exit_code == ERROR_BUSY;
}

DWORD ResolveChildExitCode(DWORD exit_code, bool proxy_recovery_running,
                           bool app_mutex_owned, bool guardian_mutex_owned) {
  if (exit_code == ERROR_ALREADY_EXISTS) {
    // The app uses this code only after activating an existing visible window.
    return ERROR_SUCCESS;
  }
  if (exit_code != ERROR_BUSY) {
    return exit_code;
  }
  InstanceContentionAction action = SelectInstanceContentionAction(
      false, false, proxy_recovery_running, app_mutex_owned,
      guardian_mutex_owned);
  if (action == InstanceContentionAction::kContinueStartup) {
    action = InstanceContentionAction::kShowBackgroundCleanup;
  }
  ShowInstanceContentionNotice(action);
  return ERROR_BUSY;
}
