#ifndef RUNNER_LAUNCHER_INSTANCE_CONTROL_H_
#define RUNNER_LAUNCHER_INSTANCE_CONTROL_H_

#include <windows.h>

#include <string>

#include "launcher_instance_policy.h"

bool ProcessImageMatches(HANDLE process, const std::wstring& expected_path);
bool ProcessTokensHaveSecurityParity(HANDLE first_process,
                                     HANDLE second_process,
                                     DWORD* error_code);
HANDLE OpenExistingChildProcess(const std::wstring& child_path,
                                bool activate_window, DWORD* process_id,
                                DWORD* open_error, bool* window_activated);
HANDLE FindChildProcessByPath(const std::wstring& child_path,
                              const wchar_t* child_exe_name,
                              DWORD* process_id, DWORD* open_error);
bool AdoptExistingChildProcessTree(HANDLE process_job, HANDLE child_process,
                                   const std::wstring& expected_core_path,
                                   DWORD* error_code);
bool IsNamedMutexOwned(const wchar_t* name);
void ShowInstanceContentionNotice(InstanceContentionAction action);
bool ChildExitRequiresProxyPreservation(DWORD exit_code);
DWORD ResolveChildExitCode(DWORD exit_code, bool proxy_recovery_running,
                           bool app_mutex_owned, bool guardian_mutex_owned);

#endif  // RUNNER_LAUNCHER_INSTANCE_CONTROL_H_
