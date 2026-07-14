#include <windows.h>
#include <shellapi.h>

#include <cstdlib>
#include <string>
#include <vector>

#include "system_proxy_recovery.h"

namespace {

constexpr wchar_t kChildExeName[] = L"ssrvpn_windows_app.exe";

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

bool HasUsableStandardHandle(DWORD id) {
  const HANDLE handle = ::GetStdHandle(id);
  return handle != nullptr && handle != INVALID_HANDLE_VALUE;
}

// ── UI helpers ──

void ShowError(const std::wstring& title, const std::wstring& message) {
  ::MessageBoxW(nullptr, message.c_str(), title.c_str(), MB_OK | MB_ICONERROR);
}

// ── Child process creation ──

bool CreateChildProcess(const std::wstring& child_path,
                        const std::wstring& working_directory,
                        std::wstring command_line, int show_command,
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
      has_standard_handles ? TRUE : FALSE, 0, nullptr,
      working_directory.c_str(), &startup_info, process_information);
  if (error_code != nullptr) {
    *error_code = created ? ERROR_SUCCESS : ::GetLastError();
  }
  return created == TRUE;
}

}  // namespace

// ────────────────────────────────────────────────────────────────────────
//  Entry point
// ────────────────────────────────────────────────────────────────────────

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE previous,
                      _In_ wchar_t* command_line, _In_ int show_command) {
  const std::wstring launcher_path = GetExecutablePath();
  const std::wstring launcher_directory = GetDirectoryName(launcher_path);
  const std::wstring child_directory = JoinPath(launcher_directory, L"bin");
  const std::wstring child_path = JoinPath(child_directory, kChildExeName);

  if (::GetFileAttributesW(child_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    ShowError(L"SSRVPN",
              L"找不到 SSRVPN 主程序：\n\n" + child_path +
                  L"\n\n请完整解压 ZIP 后再运行，不能只复制 ssrvpn_windows.exe。"
                  L"\n也可以改用 SSRVPN 安装版。"
    );
    return ERROR_FILE_NOT_FOUND;
  }

  const std::wstring child_command_line = BuildChildCommandLine(child_path);

  PROCESS_INFORMATION process_information = {};
  DWORD error = ERROR_SUCCESS;
  const bool created = CreateChildProcess(
      child_path, child_directory, child_command_line, show_command,
      &process_information, &error);

  if (!created) {
    ShowError(L"SSRVPN",
              L"无法启动 SSRVPN 主程序：\n\n" +
                  GetLastErrorMessage(error));
    return static_cast<int>(error);
  }

  // ── Normal operation: wait for child to exit ──
  ::WaitForSingleObject(process_information.hProcess, INFINITE);
  DWORD exit_code = EXIT_FAILURE;
  if (!::GetExitCodeProcess(process_information.hProcess, &exit_code)) {
    exit_code = ::GetLastError();
  }
  ::CloseHandle(process_information.hThread);
  ::CloseHandle(process_information.hProcess);
  if (exit_code != ERROR_ALREADY_EXISTS) {
    RestoreOwnedWindowsProxy();
  } else {
    // A short-lived secondary child only activated the existing window. Its
    // launcher must not restore the proxy still owned by the primary process.
    exit_code = EXIT_SUCCESS;
  }
  return static_cast<int>(exit_code);
}
