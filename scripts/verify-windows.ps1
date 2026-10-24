[CmdletBinding()]
param(
    [ValidateSet('All', 'Preflight', 'Assets')]
    [string]$Mode = 'All',
    [string]$BashPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$originalPath = $env:PATH
$exitCode = 1

try {
    if ([string]::IsNullOrWhiteSpace($BashPath)) {
        foreach ($gitCommand in @(Get-Command git.exe -All -CommandType Application -ErrorAction Stop)) {
            $gitRoot = Split-Path -Parent (Split-Path -Parent $gitCommand.Source)
            $candidate = Join-Path $gitRoot 'bin\bash.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $BashPath = $candidate
                break
            }
        }
    }
    if ([string]::IsNullOrWhiteSpace($BashPath) -or
        -not (Test-Path -LiteralPath $BashPath -PathType Leaf)) {
        throw 'Git for Windows Bash was not found. Pass -BashPath with its bin\bash.exe path.'
    }
    $BashPath = (Resolve-Path -LiteralPath $BashPath).Path
    $gitRoot = Split-Path -Parent (Split-Path -Parent $BashPath)
    $gitBin = Join-Path $gitRoot 'bin'
    $gitUsrBin = Join-Path $gitRoot 'usr\bin'
    # Keep Git Bash ahead of the Windows WSL launcher; expose Git's OpenSSL.
    $env:PATH = "$gitBin;$gitUsrBin;$originalPath"
    $entrypoint = Join-Path $PSScriptRoot 'verify-all.sh'
    $arguments = @($entrypoint.Replace('\', '/'))
    if ($Mode -eq 'Preflight') { $arguments += '--preflight' }
    if ($Mode -eq 'Assets') { $arguments += '--assets-only' }
    Push-Location -LiteralPath $repoRoot
    try {
        & $BashPath @arguments
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
} catch {
    $exitCode = 1
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
} finally {
    $env:PATH = $originalPath
}
exit $exitCode
