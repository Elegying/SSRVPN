function Assert-CleanPackagePayload {
  param([Parameter(Mandatory = $true)][string]$Root)

  Set-StrictMode -Version Latest
  if ([string]::IsNullOrWhiteSpace($Root) -or
      -not [System.IO.Path]::IsPathRooted($Root)) {
    throw 'Package payload root must be an absolute path.'
  }
  $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd(
    [char[]]@('\', '/'))
  $filesystemRoot = [System.IO.Path]::GetPathRoot($rootPath).TrimEnd(
    [char[]]@('\', '/'))
  if ($rootPath -ieq $filesystemRoot) {
    throw 'Package payload root must not be a filesystem root.'
  }

  $rootItem = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
  if (-not $rootItem.PSIsContainer -or
      (([int]$rootItem.Attributes -band
        [int][System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
    throw "Package payload root is not a real directory: $rootPath"
  }

  foreach ($relativePath in @('ssrvpn', 'bin\ssrvpn')) {
    $candidate = Join-Path $rootPath $relativePath
    if (Test-Path -LiteralPath $candidate) {
      throw (
        'Installer payload must not contain user-owned data: ' +
        $relativePath)
    }
  }
}
