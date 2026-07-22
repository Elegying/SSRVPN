enum SystemProxyOwnershipStatus {
  owned,
  externallyChanged,
  unavailable,
}

/// Captures the proxy state observed before unexpected-exit cleanup.
///
/// A null [ownershipBeforeClear] means the exited core used TUN, where system
/// proxy ownership is irrelevant. Cleanup remains allowed for unsafe states,
/// but only an owned system proxy (or TUN) may proceed to automatic restart.
class DesktopUnexpectedExitProxyCleanupResult {
  const DesktopUnexpectedExitProxyCleanupResult({
    required this.proxyCleared,
    required this.ownershipBeforeClear,
    required this.ownershipChangedDuringClear,
  });

  final bool proxyCleared;
  final SystemProxyOwnershipStatus? ownershipBeforeClear;
  final bool ownershipChangedDuringClear;

  bool get hasUnsafeSystemProxyOwnership =>
      ownershipChangedDuringClear ||
      (ownershipBeforeClear != null &&
          ownershipBeforeClear != SystemProxyOwnershipStatus.owned);

  bool get permitsAutomaticRestart =>
      proxyCleared && !hasUnsafeSystemProxyOwnership;
}

const desktopSystemProxyOwnershipLostPrefix = 'SYSTEM_PROXY_OWNERSHIP_LOST:';
const desktopSystemProxyOwnershipUnavailablePrefix =
    'SYSTEM_PROXY_OWNERSHIP_UNAVAILABLE:';
