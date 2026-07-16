#include <windows.h>
#include <sddl.h>
#include <tlhelp32.h>

#include <iostream>
#include <string>
#include <vector>

namespace {

struct TokenSecurity {
  TOKEN_ELEVATION_TYPE elevation_type = TokenElevationTypeDefault;
  DWORD integrity_rid = 0;
};

bool ReadTokenSecurity(HANDLE process, TokenSecurity* security) {
  HANDLE token = nullptr;
  if (!::OpenProcessToken(process, TOKEN_QUERY, &token)) return false;

  DWORD bytes = 0;
  bool ok = ::GetTokenInformation(token, TokenElevationType,
                                  &security->elevation_type,
                                  sizeof(security->elevation_type), &bytes) !=
            FALSE;
  ::GetTokenInformation(token, TokenIntegrityLevel, nullptr, 0, &bytes);
  std::vector<unsigned char> buffer(bytes);
  if (ok && bytes != 0 &&
      ::GetTokenInformation(token, TokenIntegrityLevel, buffer.data(), bytes,
                            &bytes)) {
    const auto* label =
        reinterpret_cast<const TOKEN_MANDATORY_LABEL*>(buffer.data());
    const UCHAR count = *::GetSidSubAuthorityCount(label->Label.Sid);
    if (count == 0) {
      ok = false;
    } else {
      security->integrity_rid =
          *::GetSidSubAuthority(label->Label.Sid, count - 1);
    }
  } else {
    ok = false;
  }
  ::CloseHandle(token);
  return ok;
}

DWORD ParentProcessId(DWORD process_id) {
  HANDLE snapshot = ::CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return 0;
  PROCESSENTRY32W entry = {};
  entry.dwSize = sizeof(entry);
  for (BOOL more = ::Process32FirstW(snapshot, &entry); more;
       more = ::Process32NextW(snapshot, &entry)) {
    if (entry.th32ProcessID == process_id) {
      ::CloseHandle(snapshot);
      return entry.th32ParentProcessID;
    }
  }
  ::CloseHandle(snapshot);
  return 0;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc == 2 && std::wstring(argv[1]) == L"--probe-child") {
    ::Sleep(5000);
    return 0;
  }
  const bool use_low_token =
      argc == 2 && std::wstring(argv[1]) == L"--explicit-low-token";

  HANDLE job = ::CreateJobObjectW(nullptr, nullptr);
  if (job == nullptr || !::AssignProcessToJobObject(job, ::GetCurrentProcess())) {
    std::wcerr << L"assign-current-to-job failed: " << ::GetLastError()
               << L"\n";
    if (job != nullptr) ::CloseHandle(job);
    return 2;
  }

  HWND shell_window = ::GetShellWindow();
  DWORD shell_id = 0;
  ::GetWindowThreadProcessId(shell_window, &shell_id);
  HANDLE shell_process = ::OpenProcess(
      PROCESS_CREATE_PROCESS | PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
      shell_id);
  if (shell_process == nullptr) {
    std::wcerr << L"open-shell failed: " << ::GetLastError() << L"\n";
    ::CloseHandle(job);
    return 3;
  }

  HANDLE token = nullptr;
  if (!::OpenProcessToken(::GetCurrentProcess(),
                          TOKEN_QUERY | TOKEN_DUPLICATE |
                              TOKEN_ASSIGN_PRIMARY,
                          &token)) {
    std::wcerr << L"open-current-token failed: " << ::GetLastError() << L"\n";
    ::CloseHandle(shell_process);
    ::CloseHandle(job);
    return 4;
  }
  TokenSecurity expected_security;
  if (!ReadTokenSecurity(::GetCurrentProcess(), &expected_security)) {
    ::CloseHandle(token);
    ::CloseHandle(shell_process);
    ::CloseHandle(job);
    return 4;
  }
  if (use_low_token) {
    HANDLE low_token = nullptr;
    PSID low_sid = nullptr;
    if (!::DuplicateTokenEx(token, TOKEN_QUERY | TOKEN_DUPLICATE |
                                      TOKEN_ASSIGN_PRIMARY |
                                      TOKEN_ADJUST_DEFAULT,
                            nullptr, SecurityImpersonation, TokenPrimary,
                            &low_token) ||
        !::ConvertStringSidToSidW(L"S-1-16-4096", &low_sid)) {
      std::wcerr << L"create-low-token failed: " << ::GetLastError() << L"\n";
      if (low_token != nullptr) ::CloseHandle(low_token);
      ::CloseHandle(token);
      ::CloseHandle(shell_process);
      ::CloseHandle(job);
      return 4;
    }
    TOKEN_MANDATORY_LABEL label = {};
    label.Label.Attributes = SE_GROUP_INTEGRITY;
    label.Label.Sid = low_sid;
    const BOOL integrity_set = ::SetTokenInformation(
        low_token, TokenIntegrityLevel, &label,
        sizeof(label) + ::GetLengthSid(low_sid));
    ::LocalFree(low_sid);
    if (!integrity_set) {
      std::wcerr << L"set-low-integrity failed: " << ::GetLastError() << L"\n";
      ::CloseHandle(low_token);
      ::CloseHandle(token);
      ::CloseHandle(shell_process);
      ::CloseHandle(job);
      return 4;
    }
    ::CloseHandle(token);
    token = low_token;
    expected_security.integrity_rid = SECURITY_MANDATORY_LOW_RID;
  }

  SIZE_T attribute_bytes = 0;
  ::InitializeProcThreadAttributeList(nullptr, 1, 0, &attribute_bytes);
  std::vector<unsigned char> attribute_storage(attribute_bytes);
  auto* attributes = reinterpret_cast<PPROC_THREAD_ATTRIBUTE_LIST>(
      attribute_storage.data());
  if (attribute_bytes == 0 ||
      !::InitializeProcThreadAttributeList(attributes, 1, 0,
                                           &attribute_bytes) ||
      !::UpdateProcThreadAttribute(
          attributes, 0, PROC_THREAD_ATTRIBUTE_PARENT_PROCESS,
          &shell_process, sizeof(shell_process), nullptr, nullptr)) {
    std::wcerr << L"parent-attribute failed: " << ::GetLastError() << L"\n";
    ::CloseHandle(token);
    ::CloseHandle(shell_process);
    ::CloseHandle(job);
    return 5;
  }

  std::wstring executable(32768, L'\0');
  const DWORD length = ::GetModuleFileNameW(
      nullptr, executable.data(), static_cast<DWORD>(executable.size()));
  executable.resize(length);
  std::wstring command = L"\"" + executable + L"\" --probe-child";
  STARTUPINFOEXW startup = {};
  startup.StartupInfo.cb = sizeof(startup);
  startup.lpAttributeList = attributes;
  PROCESS_INFORMATION child = {};
  const BOOL created = ::CreateProcessAsUserW(
      token, executable.c_str(), command.data(), nullptr, nullptr, FALSE,
      EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW, nullptr, nullptr,
      &startup.StartupInfo, &child);
  const DWORD create_error = created ? ERROR_SUCCESS : ::GetLastError();
  ::DeleteProcThreadAttributeList(attributes);
  ::CloseHandle(token);
  ::CloseHandle(shell_process);
  if (!created) {
    std::wcerr << L"CreateProcessAsUser failed: " << create_error << L"\n";
    ::CloseHandle(job);
    return 6;
  }
  ::CloseHandle(child.hThread);

  TokenSecurity child_security;
  BOOL child_in_outer_job = TRUE;
  const bool parity = ReadTokenSecurity(child.hProcess, &child_security) &&
                      expected_security.elevation_type ==
                          child_security.elevation_type &&
                      expected_security.integrity_rid ==
                          child_security.integrity_rid;
  const bool job_query =
      ::IsProcessInJob(child.hProcess, job, &child_in_outer_job) != FALSE;
  const DWORD observed_parent = ParentProcessId(child.dwProcessId);
  std::wcout << L"parity=" << parity
             << L" expected_elevation=" << expected_security.elevation_type
             << L" child_elevation=" << child_security.elevation_type
             << L" expected_integrity=" << expected_security.integrity_rid
             << L" child_integrity=" << child_security.integrity_rid
             << L" in_outer_job=" << child_in_outer_job
             << L" parent=" << observed_parent << L" shell=" << shell_id
             << L"\n";

  ::TerminateProcess(child.hProcess, 0);
  ::WaitForSingleObject(child.hProcess, 5000);
  ::CloseHandle(child.hProcess);
  ::CloseHandle(job);
  return parity && job_query && !child_in_outer_job &&
                 observed_parent == shell_id
             ? 0
             : 7;
}
