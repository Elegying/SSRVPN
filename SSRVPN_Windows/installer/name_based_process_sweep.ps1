# Name-based process sweep for stop_ssrvpn_processes.ps1.
# Product decision (docs/decisions/021-installer-name-based-process-stop.md,
# 2026-09-22): install and uninstall stop every process whose exact image name
# matches an SSRVPN-shipped executable, wherever that copy runs - the current
# install directory, an older install directory, or a portable/extracted copy.
# Path-exact matching could not serve real novice users: a copy launched from
# any third directory (or a portable copy) still held the global
# single-instance gate and blocked the install with APP_INSTANCE_ACTIVE. The
# closed allow-list below names only this product's executables; generic
# third-party names (Clash, OpenVPN, WireGuard, Tailscale, ZeroTier, ...) are
# never matched, and tests pin the list. Files of old copies on disk are still
# never searched, moved, modified, or deleted.

# Exact image names shipped by this product's Windows distribution.
$script:OwnImageNames = @(
  'ssrvpn_windows_app.exe', 'ssrvpn_windows.exe', 'mihomo.exe')

# Enumerates every live process with one of the SSRVPN-shipped image names,
# regardless of its executable path. Each returned PID is re-verified (live
# name, session, image path, creation time) inside Get-ProcessesAtPath and
# again inside Stop-VerifiedProcess immediately before termination, so a stale
# CIM row or PID reuse is never terminated blindly.
function Get-ImageNameProcessesFailClosed {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Phase
  )
  if ($script:OwnImageNames -cnotcontains $Name) {
    throw "Image name '$Name' is not an SSRVPN-shipped executable."
  }
  return @(Get-ProcessesAtPathFailClosed `
    -Name $Name -ExpectedPath '' -Phase $Phase)
}
