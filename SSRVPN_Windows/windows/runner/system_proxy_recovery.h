#ifndef RUNNER_SYSTEM_PROXY_RECOVERY_H_
#define RUNNER_SYSTEM_PROXY_RECOVERY_H_

// Serializes WinINet proxy ownership changes across the Dart app and native
// crash recovery. The byte-range lock is released automatically if a process
// exits unexpectedly.
class WindowsProxyTransactionLock final {
 public:
  WindowsProxyTransactionLock() noexcept;
  ~WindowsProxyTransactionLock();

  WindowsProxyTransactionLock(const WindowsProxyTransactionLock&) = delete;
  WindowsProxyTransactionLock& operator=(
      const WindowsProxyTransactionLock&) = delete;

  bool acquired() const noexcept;

 private:
  void* file_handle_ = nullptr;
};

// Synchronously restores the pre-SSRVPN WinINet settings, or confirms that no
// SSRVPN-owned endpoint remains. Returns false when recovery must be retried.
bool RestoreOwnedWindowsProxy() noexcept;
bool RestoreOwnedWindowsProxy(
    const WindowsProxyTransactionLock& transaction_lock) noexcept;

// Returns false only while Windows still points at the SSRVPN-owned localhost
// endpoint, or when that state cannot be verified safely.
bool IsOwnedWindowsProxySafeToStop() noexcept;
bool IsOwnedWindowsProxySafeToStop(
    const WindowsProxyTransactionLock& transaction_lock) noexcept;

// Performs restore-or-confirm-safe while holding one transaction lock.
bool RestoreOrConfirmOwnedWindowsProxySafeToStop() noexcept;

// Re-registers the recovery-only child command after Windows consumes its
// RunOnce value. Used only while an owned endpoint is still unsafe.
bool RearmWindowsProxyRecoveryRunOnce() noexcept;
bool RearmWindowsProxyRecoveryRunOnce(
    const wchar_t* recovery_executable) noexcept;

#endif  // RUNNER_SYSTEM_PROXY_RECOVERY_H_
