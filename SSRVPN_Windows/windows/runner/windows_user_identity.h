#ifndef RUNNER_WINDOWS_USER_IDENTITY_H_
#define RUNNER_WINDOWS_USER_IDENTITY_H_

#include <string>
#include <windows.h>

namespace windows_user_identity {

// Returns the current process token's user SID as its canonical string form.
// An empty string means the identity could not be established safely.
std::wstring QueryCurrentUserSid();
std::wstring QueryProcessUserSid(HANDLE process);
bool SameUser(const std::wstring& current_sid, const std::wstring& other_sid);
bool IsCurrentUserInteractiveUser();

}  // namespace windows_user_identity

#endif  // RUNNER_WINDOWS_USER_IDENTITY_H_
