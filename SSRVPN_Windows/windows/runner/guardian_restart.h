#ifndef RUNNER_GUARDIAN_RESTART_H_
#define RUNNER_GUARDIAN_RESTART_H_

#include <windows.h>

template <typename StartGuardian>
bool RetryGuardianStart(DWORD attempts, DWORD delay_milliseconds,
                        StartGuardian start_guardian) {
  for (DWORD attempt = 0; attempt < attempts; ++attempt) {
    if (start_guardian()) return true;
    if (attempt + 1 < attempts) ::Sleep(delay_milliseconds);
  }
  return false;
}

#endif  // RUNNER_GUARDIAN_RESTART_H_
