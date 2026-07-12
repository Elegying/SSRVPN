#ifndef RUNNER_SYSTEM_PROXY_RECOVERY_H_
#define RUNNER_SYSTEM_PROXY_RECOVERY_H_

// Synchronously restores the pre-SSRVPN WinINet settings during Windows
// logoff/shutdown, but only while the complete proxy fingerprint is still
// owned by SSRVPN.
bool RestoreOwnedWindowsProxy() noexcept;

#endif  // RUNNER_SYSTEM_PROXY_RECOVERY_H_
