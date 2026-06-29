#include "startup_diagnostics.h"

#include <dbghelp.h>

#include <iomanip>
#include <sstream>
#include <string>

namespace {

std::wstring g_root_dir;
std::wstring g_log_path;

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

std::wstring ExceptionCodeToString(DWORD code) {
  std::wstringstream stream;
  stream << L"0x" << std::hex << std::uppercase << code;
  return stream.str();
}

void AppendLine(const std::wstring& line) {
  if (g_log_path.empty()) {
    return;
  }

  HANDLE file = ::CreateFileW(g_log_path.c_str(), FILE_APPEND_DATA,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }

  std::string utf8 = WideToUtf8(line + L"\r\n");
  DWORD written = 0;
  if (!utf8.empty()) {
    ::WriteFile(file, utf8.data(), static_cast<DWORD>(utf8.size()), &written,
                nullptr);
  }
  ::FlushFileBuffers(file);
  ::CloseHandle(file);
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
