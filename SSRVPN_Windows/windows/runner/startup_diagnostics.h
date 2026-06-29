#ifndef RUNNER_STARTUP_DIAGNOSTICS_H_
#define RUNNER_STARTUP_DIAGNOSTICS_H_

#include <windows.h>

#include <string>

namespace startup_diagnostics {

void Initialize();
void Log(const std::wstring& message);
std::wstring GetExecutablePath();
int WriteDumpAndContinue(EXCEPTION_POINTERS* info,
                         const std::wstring& context);
int WriteDumpAndContinue(EXCEPTION_POINTERS* info, const wchar_t* context);

}  // namespace startup_diagnostics

#endif  // RUNNER_STARTUP_DIAGNOSTICS_H_
