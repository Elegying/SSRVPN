# Removes security exceptions created by SSRVPN 2.4.5 and earlier.
# This script only restores the Windows default mitigation policy; it never
# disables a mitigation. Run it once from an Administrator PowerShell.

$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    Write-Error 'Administrator privileges are required.'
    exit 1
}

$failed = $false
foreach ($name in @('ssrvpn_windows.exe', 'ssrvpn_windows_app.exe')) {
    try {
        Set-ProcessMitigation -Name $name -Remove -Disable UserShadowStack `
            -ErrorAction Stop

        $legacyPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' +
            "\Image File Execution Options\$name"
        if (Test-Path -LiteralPath $legacyPath) {
            Remove-ItemProperty -LiteralPath $legacyPath `
                -Name 'DisableUserShadowStack' -ErrorAction SilentlyContinue
        }

        $policy = Get-ProcessMitigation -Name $name -ErrorAction SilentlyContinue
        if ($policy -and $policy.UserShadowStack -eq 'OFF') {
            throw "UserShadowStack is still disabled for $name"
        }
        Write-Host "[OK] Restored Windows mitigation defaults for $name"
    } catch {
        Write-Warning "Failed to restore mitigation defaults for ${name}: $_"
        $failed = $true
    }
}

if ($failed) { exit 1 }
Write-Host 'Legacy SSRVPN mitigation exceptions have been removed.'
