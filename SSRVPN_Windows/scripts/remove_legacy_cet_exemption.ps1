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
    $mitigationRemoved = $false
    try {
        Set-ProcessMitigation -Name $name -Remove -Disable UserShadowStack `
            -ErrorAction Stop
        $mitigationRemoved = $true
    } catch {
        Write-Warning "Failed to remove the structured mitigation for ${name}: $_"
    }

    $legacyPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' +
        "\Image File Execution Options\$name"
    $legacyRemoved = $false
    try {
        if (Test-Path -LiteralPath $legacyPath) {
            $legacyValue = Get-ItemProperty -LiteralPath $legacyPath `
                -Name 'DisableUserShadowStack' -ErrorAction SilentlyContinue
            if ($null -ne $legacyValue -and
                $null -ne $legacyValue.DisableUserShadowStack) {
                Remove-ItemProperty -LiteralPath $legacyPath `
                    -Name 'DisableUserShadowStack' -ErrorAction Stop
            }

            $remaining = Get-ItemProperty -LiteralPath $legacyPath `
                -Name 'DisableUserShadowStack' -ErrorAction SilentlyContinue
            if ($null -ne $remaining -and
                $null -ne $remaining.DisableUserShadowStack) {
                throw "DisableUserShadowStack is still present for $name"
            }
        }
        $legacyRemoved = $true
    } catch {
        Write-Warning "Failed to remove the legacy registry value for ${name}: $_"
    }

    $policyVerified = $false
    try {
        $policy = Get-ProcessMitigation -Name $name -ErrorAction SilentlyContinue
        if ($policy -and $policy.UserShadowStack -eq 'OFF') {
            throw "UserShadowStack is still disabled for $name"
        }
        $policyVerified = $true
    } catch {
        Write-Warning "Failed to verify mitigation defaults for ${name}: $_"
    }

    if ($mitigationRemoved -and $legacyRemoved -and $policyVerified) {
        Write-Host "[OK] Restored Windows mitigation defaults for $name"
    } else {
        $failed = $true
    }
}

if ($failed) { exit 1 }
Write-Host 'Legacy SSRVPN mitigation exceptions have been removed.'
