#include "startup_diagnostics.h"

#include <dbghelp.h>
#include <shlobj.h>

#include <algorithm>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

namespace {

std::wstring g_root_dir;
std::wstring g_log_path;
std::wstring g_desktop_dir;
std::wstring g_last_dump_path;
bool g_normal_shutdown_started = false;

std::wstring GetLocalAppData();

std::wstring JoinPath(const std::wstring& left, const std::wstring& right) {
  if (left.empty()) {
    return right;
  }
  if (left.back() == L'\\' || left.back() == L'/') {
    return left + right;
  }
  return left + L"\\" + right;
}

void EnsureDirectory(const std::wstring& path) {
  if (path.empty()) {
    return;
  }
  ::CreateDirectoryW(path.c_str(), nullptr);
}

std::wstring GetDesktopDirectory() {
  PWSTR known_folder = nullptr;
  HRESULT result = ::SHGetKnownFolderPath(FOLDERID_Desktop, 0, nullptr,
                                          &known_folder);
  if (SUCCEEDED(result) && known_folder != nullptr) {
    std::wstring desktop(known_folder);
    ::CoTaskMemFree(known_folder);
    if (!desktop.empty()) {
      return desktop;
    }
  }

  wchar_t buffer[MAX_PATH];
  DWORD length = ::GetEnvironmentVariableW(L"USERPROFILE", buffer, MAX_PATH);
  if (length > 0 && length < MAX_PATH) {
    return JoinPath(std::wstring(buffer, length), L"Desktop");
  }
  return GetLocalAppData();
}

std::wstring GetLocalAppData() {
  wchar_t buffer[MAX_PATH];
  DWORD length = ::GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH);
  if (length > 0 && length < MAX_PATH) {
    return std::wstring(buffer, length);
  }

  length = ::GetTempPathW(MAX_PATH, buffer);
  if (length > 0 && length < MAX_PATH) {
    return std::wstring(buffer, length);
  }
  return L".";
}

std::wstring TimestampForLine() {
  SYSTEMTIME time;
  ::GetLocalTime(&time);
  std::wstringstream stream;
  stream << std::setfill(L'0') << std::setw(4) << time.wYear << L'-'
         << std::setw(2) << time.wMonth << L'-' << std::setw(2) << time.wDay
         << L'T' << std::setw(2) << time.wHour << L':' << std::setw(2)
         << time.wMinute << L':' << std::setw(2) << time.wSecond << L'.'
         << std::setw(3) << time.wMilliseconds;
  return stream.str();
}

std::wstring TimestampForFile() {
  SYSTEMTIME time;
  ::GetLocalTime(&time);
  std::wstringstream stream;
  stream << std::setfill(L'0') << std::setw(4) << time.wYear << std::setw(2)
         << time.wMonth << std::setw(2) << time.wDay << L'_' << std::setw(2)
         << time.wHour << std::setw(2) << time.wMinute << std::setw(2)
         << time.wSecond << L'_' << std::setw(3) << time.wMilliseconds;
  return stream.str();
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return std::string();
  }
  int size = ::WideCharToMultiByte(CP_UTF8, 0, value.data(),
                                  static_cast<int>(value.size()), nullptr, 0,
                                  nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string result(size, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, value.data(),
                        static_cast<int>(value.size()), result.data(), size,
                        nullptr, nullptr);
  return result;
}

void AppendUtf8ToFile(const std::wstring& path, const std::string& text) {
  if (path.empty()) {
    return;
  }

  HANDLE file = ::CreateFileW(path.c_str(), FILE_APPEND_DATA,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }

  DWORD written = 0;
  if (!text.empty()) {
    ::WriteFile(file, text.data(), static_cast<DWORD>(text.size()), &written,
                nullptr);
  }
  ::FlushFileBuffers(file);
  ::CloseHandle(file);
}

void AppendWideLineToFile(const std::wstring& path, const std::wstring& line) {
  AppendUtf8ToFile(path, WideToUtf8(line + L"\r\n"));
}

std::string ReadFileUtf8(const std::wstring& path) {
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_READ,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return std::string();
  }

  LARGE_INTEGER size;
  if (!::GetFileSizeEx(file, &size) || size.QuadPart <= 0) {
    ::CloseHandle(file);
    return std::string();
  }

  const DWORD max_bytes = 1024 * 1024;
  const DWORD bytes_to_read =
      static_cast<DWORD>(std::min<LONGLONG>(size.QuadPart, max_bytes));
  std::vector<char> buffer(bytes_to_read);
  DWORD bytes_read = 0;
  ::ReadFile(file, buffer.data(), bytes_to_read, &bytes_read, nullptr);
  ::CloseHandle(file);

  return std::string(buffer.data(), bytes_read);
}

std::wstring ExceptionCodeToString(DWORD code) {
  std::wstringstream stream;
  stream << L"0x" << std::hex << std::uppercase << code;
  return stream.str();
}

void AppendLine(const std::wstring& line) {
  AppendWideLineToFile(g_log_path, line);
}

std::wstring DesktopFailurePath() {
  const std::wstring dir =
      g_desktop_dir.empty() ? GetDesktopDirectory() : g_desktop_dir;
  EnsureDirectory(dir);

  std::wstringstream name;
  name << L"SSRVPN_Startup_Failure_" << TimestampForFile() << L"_pid"
       << ::GetCurrentProcessId() << L".log";
  return JoinPath(dir, name.str());
}

std::wstring DumpPath() {
  const std::wstring crash_dir = JoinPath(g_root_dir, L"crashes");
  EnsureDirectory(crash_dir);

  std::wstringstream name;
  name << L"ssrvpn_" << TimestampForFile() << L"_pid"
       << ::GetCurrentProcessId() << L".dmp";
  return JoinPath(crash_dir, name.str());
}

LONG WINAPI UnhandledFilter(EXCEPTION_POINTERS* info) {
  startup_diagnostics::WriteDumpAndContinue(info, L"unhandled exception");
  if (g_normal_shutdown_started) {
    AppendLine(L"desktop startup failure report skipped during normal shutdown");
  } else {
    startup_diagnostics::WriteDesktopFailureLog(L"unhandled exception");
  }
  return EXCEPTION_EXECUTE_HANDLER;
}

LONG CALLBACK VectoredHandler(EXCEPTION_POINTERS* info) {
  if (info != nullptr && info->ExceptionRecord != nullptr &&
      info->ExceptionRecord->ExceptionCode == 0x406D1388) {
    return EXCEPTION_CONTINUE_SEARCH;
  }
  startup_diagnostics::WriteDumpAndContinue(info, L"vectored exception");
  return EXCEPTION_CONTINUE_SEARCH;
}

}  // namespace

namespace startup_diagnostics {

void Initialize() {
  g_root_dir = JoinPath(GetLocalAppData(), L"SSRVPN");
  g_desktop_dir = GetDesktopDirectory();
  EnsureDirectory(g_root_dir);
  EnsureDirectory(JoinPath(g_root_dir, L"logs"));
  EnsureDirectory(JoinPath(g_root_dir, L"crashes"));
  g_log_path = JoinPath(JoinPath(g_root_dir, L"logs"), L"startup.log");

  ::SetUnhandledExceptionFilter(UnhandledFilter);
  ::AddVectoredExceptionHandler(1, VectoredHandler);
}

void Log(const std::wstring& message) {
  AppendLine(L"[" + TimestampForLine() + L"] [native] " + message);
}

void MarkNormalShutdown() {
  g_normal_shutdown_started = true;
  Log(L"normal shutdown started");
}

void WriteDesktopFailureLog(const std::wstring& context) {
  const std::wstring report_path = DesktopFailurePath();
  AppendWideLineToFile(report_path, L"SSRVPN startup failure report");
  AppendWideLineToFile(report_path, L"Generated: " + TimestampForLine());
  AppendWideLineToFile(report_path, L"Reason: " + context);
  AppendWideLineToFile(report_path,
                       L"Executable: " + GetExecutablePath());
  AppendWideLineToFile(report_path,
                       std::wstring(L"Command line: ") + ::GetCommandLineW());
  AppendWideLineToFile(report_path, L"Startup log: " + g_log_path);
  if (!g_last_dump_path.empty()) {
    AppendWideLineToFile(report_path, L"Crash dump: " + g_last_dump_path);
  }
  AppendWideLineToFile(report_path, L"");
  AppendWideLineToFile(report_path, L"---- startup.log ----");

  const std::string startup_log = ReadFileUtf8(g_log_path);
  if (startup_log.empty()) {
    AppendWideLineToFile(report_path, L"<startup.log is empty or missing>");
  } else {
    AppendUtf8ToFile(report_path, startup_log);
    if (startup_log.size() < 2 ||
        startup_log.substr(startup_log.size() - 2) != "\r\n") {
      AppendUtf8ToFile(report_path, "\r\n");
    }
  }

  Log(L"desktop startup failure report written: " + report_path);
}

std::wstring GetExecutablePath() {
  wchar_t buffer[MAX_PATH];
  DWORD length = ::GetModuleFileNameW(nullptr, buffer, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return L"<unknown>";
  }
  return std::wstring(buffer, length);
}

int WriteDumpAndContinue(EXCEPTION_POINTERS* info,
                         const std::wstring& context) {
  if (info == nullptr || info->ExceptionRecord == nullptr) {
    Log(context + L": exception record unavailable");
    return EXCEPTION_EXECUTE_HANDLER;
  }

  const DWORD code = info->ExceptionRecord->ExceptionCode;
  Log(context + L": code=" + ExceptionCodeToString(code));

  const std::wstring dump_path = DumpPath();
  g_last_dump_path = dump_path;
  HANDLE file = ::CreateFileW(dump_path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    Log(L"minidump create failed: " + dump_path);
    return EXCEPTION_EXECUTE_HANDLER;
  }

  MINIDUMP_EXCEPTION_INFORMATION dump_exception;
  dump_exception.ThreadId = ::GetCurrentThreadId();
  dump_exception.ExceptionPointers = info;
  dump_exception.ClientPointers = FALSE;

  const BOOL ok = ::MiniDumpWriteDump(
      ::GetCurrentProcess(), ::GetCurrentProcessId(), file, MiniDumpNormal,
      &dump_exception, nullptr, nullptr);
  ::CloseHandle(file);

  if (ok) {
    Log(L"minidump written: " + dump_path);
  } else {
    Log(L"minidump write failed: " + dump_path);
  }
  return EXCEPTION_EXECUTE_HANDLER;
}

int WriteDumpAndContinue(EXCEPTION_POINTERS* info, const wchar_t* context) {
  return WriteDumpAndContinue(
      info, std::wstring(context != nullptr ? context : L"<unknown>"));
}

}  // namespace startup_diagnostics
