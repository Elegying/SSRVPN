[CmdletBinding()]
param(
  [switch]$SkipBuild,
  [string]$FlutterExe,
  [string]$LogPath,
  [switch]$ChinaMirror,
  [switch]$NoMirrorFallback,
  [switch]$OfflinePub,
  [string]$PubHostedUrl,
  [string]$FlutterStorageBaseUrl
)

$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath(
  (Join-Path $PSScriptRoot '..')
)
$buildDir = Join-Path $projectRoot 'build\windows\x64\runner\Release'
$releaseDir = Join-Path $projectRoot 'SSRVPN_Windows_Release'
$binDir = Join-Path $releaseDir 'bin'
$zipPath = Join-Path $projectRoot 'SSRVPN.zip'
$zipHashPath = "$zipPath.sha256"
$defaultChinaPubHostedUrl = 'https://pub.flutter-io.cn'
$defaultChinaFlutterStorageBaseUrl = 'https://storage.flutter-io.cn'
$originalPubHostedUrl = $env:PUB_HOSTED_URL
$originalFlutterStorageBaseUrl = $env:FLUTTER_STORAGE_BASE_URL

function Get-AppDisplayVersion {
  $pubspecPath = Join-Path $projectRoot 'pubspec.yaml'
  foreach ($line in Get-Content -LiteralPath $pubspecPath -Encoding UTF8) {
    if ($line -match '^version:\s+([^\s]+)') {
      $semanticVersion = ($matches[1] -split '\+')[0]
      return "v$semanticVersion"
    }
  }
  throw "Could not read version from $pubspecPath"
}

function Copy-PortableReadme {
  param([Parameter(Mandatory = $true)][string]$Destination)

  $source = Join-Path $projectRoot 'PORTABLE_README.txt'
  $lines = @(Get-Content -LiteralPath $source -Encoding UTF8)
  if ($lines.Count -eq 0) {
    throw "Portable readme is empty: $source"
  }
  # Preserve the UTF-8 title read from the guide. Windows PowerShell 5.1 may
  # decode non-ASCII literals in a BOM-less .ps1 file using the active codepage.
  $lines[0] = "$($lines[0]) $(Get-AppDisplayVersion)"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllLines($Destination, $lines, $utf8NoBom)
}

$runtimeDlls = @(
  'concrt140.dll',
  'msvcp140.dll',
  'msvcp140_1.dll',
  'msvcp140_2.dll',
  'msvcp140_atomic_wait.dll',
  'msvcp140_codecvt_ids.dll',
  'vcruntime140.dll',
  'vcruntime140_1.dll'
)

$requiredFiles = @(
  'ssrvpn_windows.exe',
  'SSRVPN_Diag.bat',
  'ssrvpn_safe_mode.bat',
  'SAFE_MODE_README.txt',
  'remove_legacy_cet_exemption.ps1',
  'remove_legacy_cet_exemption.bat',
  'bin\ssrvpn_windows_app.exe',
  'bin\mihomo.exe',
  'bin\flutter_windows.dll',
  'bin\screen_retriever_windows_plugin.dll',
  'bin\system_tray_plugin.dll',
  'bin\window_manager_plugin.dll',
  'bin\d3dcompiler_47.dll',
  'bin\data\app.so',
  'bin\data\icudtl.dat',
  'bin\data\flutter_assets\assets\geoip.metadb.gz',
  'bin\data\flutter_assets\assets\icon.ico'
) + $runtimeDlls + ($runtimeDlls | ForEach-Object { "bin\$_" })

$transcriptStarted = $false
if ($LogPath -and $LogPath.Trim().Length -gt 0) {
  $resolvedLogPath = [System.IO.Path]::GetFullPath($LogPath)
  $logParent = Split-Path -Parent $resolvedLogPath
  if ($logParent -and -not (Test-Path -LiteralPath $logParent)) {
    New-Item -ItemType Directory -Path $logParent | Out-Null
  }
  try {
    Start-Transcript -Path $resolvedLogPath -Force | Out-Null
    $transcriptStarted = $true
  } catch {
    Write-Warning "Could not start build transcript: $($_.Exception.Message)"
  }
}

function Add-CandidateDirectory {
  param(
    [System.Collections.ArrayList]$List,
    [string]$Path
  )

  if ($null -eq $List) {
    throw 'Internal error: candidate directory list was not initialized.'
  }
  if (-not $Path -or $Path.Trim().Length -eq 0) {
    return
  }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    return
  }
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  if (-not $List.Contains($fullPath)) {
    [void]$List.Add($fullPath)
  }
}

function Get-PeMachine {
  param([Parameter(Mandatory = $true)][string]$Path)

  $stream = $null
  $reader = $null
  try {
    $stream = [System.IO.File]::Open(
      $Path,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::ReadWrite
    )
    if ($stream.Length -lt 0x40) {
      return $null
    }
    $reader = New-Object System.IO.BinaryReader($stream)
    [void]$stream.Seek(0x3c, [System.IO.SeekOrigin]::Begin)
    $peOffset = $reader.ReadInt32()
    if ($peOffset -le 0 -or $peOffset -gt ($stream.Length - 6)) {
      return $null
    }
    [void]$stream.Seek($peOffset, [System.IO.SeekOrigin]::Begin)
    $signature = $reader.ReadUInt32()
    if ($signature -ne 0x00004550) {
      return $null
    }
    return $reader.ReadUInt16()
  } catch {
    return $null
  } finally {
    if ($reader -ne $null) {
      $reader.Close()
    } elseif ($stream -ne $null) {
      $stream.Close()
    }
  }
}

function Get-PeDllCharacteristics {
  param([Parameter(Mandatory = $true)][string]$Path)

  $stream = $null
  $reader = $null
  try {
    $stream = [System.IO.File]::Open(
      $Path,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::ReadWrite
    )
    if ($stream.Length -lt 0x40) {
      return $null
    }
    $reader = New-Object System.IO.BinaryReader($stream)
    [void]$stream.Seek(0x3c, [System.IO.SeekOrigin]::Begin)
    $peOffset = $reader.ReadInt32()
    $optionalHeaderOffset = $peOffset + 24
    $dllCharacteristicsOffset = $optionalHeaderOffset + 0x46
    if ($peOffset -le 0 -or $dllCharacteristicsOffset -gt ($stream.Length - 2)) {
      return $null
    }
    [void]$stream.Seek($peOffset, [System.IO.SeekOrigin]::Begin)
    if ($reader.ReadUInt32() -ne 0x00004550) {
      return $null
    }
    [void]$stream.Seek($optionalHeaderOffset, [System.IO.SeekOrigin]::Begin)
    $magic = $reader.ReadUInt16()
    if ($magic -ne 0x010b -and $magic -ne 0x020b) {
      return $null
    }
    [void]$stream.Seek($dllCharacteristicsOffset, [System.IO.SeekOrigin]::Begin)
    return $reader.ReadUInt16()
  } catch {
    return $null
  } finally {
    if ($reader -ne $null) {
      $reader.Close()
    } elseif ($stream -ne $null) {
      $stream.Close()
    }
  }
}

function Test-X64PeFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  $machine = Get-PeMachine -Path $Path
  return $machine -eq 0x8664
}

function Add-VisualStudioRedistDirectories {
  param(
    [System.Collections.ArrayList]$List
  )

  if ($null -eq $List) {
    throw 'Internal error: candidate directory list was not initialized.'
  }

  $vsRoots = New-Object System.Collections.ArrayList
  $programFilesX86 = ${env:ProgramFiles(x86)}
  if ($programFilesX86) {
    $vswhere = Join-Path $programFilesX86 `
      'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
      $installations = & $vswhere -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath 2>$null
      foreach ($installation in $installations) {
        if ($installation -and -not $vsRoots.Contains($installation)) {
          [void]$vsRoots.Add($installation)
        }
      }
    }
  }

  $visualStudioBases = @()
  if ($env:ProgramFiles) {
    $visualStudioBases += (Join-Path $env:ProgramFiles 'Microsoft Visual Studio')
  }
  if ($programFilesX86) {
    $visualStudioBases += (Join-Path $programFilesX86 'Microsoft Visual Studio')
  }

  foreach ($base in $visualStudioBases) {
    foreach ($year in @('2022', '2019')) {
      foreach ($edition in @(
          'BuildTools',
          'Community',
          'Professional',
          'Enterprise'
        )) {
        $candidate = Join-Path $base (Join-Path $year $edition)
        if (
          (Test-Path -LiteralPath $candidate -PathType Container) -and
          -not $vsRoots.Contains($candidate)
        ) {
          [void]$vsRoots.Add($candidate)
        }
      }
    }
  }

  foreach ($vsRoot in $vsRoots) {
    $redistRoot = Join-Path $vsRoot 'VC\Redist\MSVC'
    if (-not (Test-Path -LiteralPath $redistRoot -PathType Container)) {
      continue
    }
    $versionDirs = Get-ChildItem -LiteralPath $redistRoot -Directory `
      -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    foreach ($versionDir in $versionDirs) {
      Add-CandidateDirectory -List $List -Path (
        Join-Path $versionDir.FullName 'x64\Microsoft.VC143.CRT'
      )
      Add-CandidateDirectory -List $List -Path (
        Join-Path $versionDir.FullName 'x64\Microsoft.VC142.CRT'
      )
    }
  }
}

function Get-PortableRuntimeSearchDirectories {
  $directories = New-Object System.Collections.ArrayList
  Add-CandidateDirectory -List $directories -Path $releaseDir
  Add-CandidateDirectory -List $directories -Path $buildDir
  Add-CandidateDirectory -List $directories -Path (Join-Path $projectRoot 'runtime')
  Add-CandidateDirectory -List $directories -Path (Join-Path $projectRoot 'redist')
  Add-CandidateDirectory -List $directories -Path (Join-Path $projectRoot 'redistributable')

  if ($env:VCToolsRedistDir) {
    Add-CandidateDirectory -List $directories -Path (
      Join-Path $env:VCToolsRedistDir 'x64\Microsoft.VC143.CRT'
    )
    Add-CandidateDirectory -List $directories -Path (
      Join-Path $env:VCToolsRedistDir 'x64\Microsoft.VC142.CRT'
    )
  }

  Add-VisualStudioRedistDirectories -List $directories

  if ($env:WINDIR) {
    Add-CandidateDirectory -List $directories -Path (Join-Path $env:WINDIR 'Sysnative')
    Add-CandidateDirectory -List $directories -Path (Join-Path $env:WINDIR 'System32')
  }
  if ($env:SystemRoot) {
    Add-CandidateDirectory -List $directories -Path (Join-Path $env:SystemRoot 'Sysnative')
    Add-CandidateDirectory -List $directories -Path (Join-Path $env:SystemRoot 'System32')
  }

  return $directories.ToArray()
}

function Get-D3DCompilerSearchDirectories {
  $directories = New-Object System.Collections.ArrayList
  Add-CandidateDirectory -List $directories -Path $releaseDir
  Add-CandidateDirectory -List $directories -Path $buildDir
  Add-CandidateDirectory -List $directories -Path $projectRoot
  Add-CandidateDirectory -List $directories -Path (Join-Path $projectRoot 'runtime')
  Add-CandidateDirectory -List $directories -Path (Join-Path $projectRoot 'redist')
  Add-CandidateDirectory -List $directories -Path (Join-Path $projectRoot 'redistributable')

  $programFilesX86 = ${env:ProgramFiles(x86)}
  if ($programFilesX86) {
    Add-CandidateDirectory -List $directories -Path (
      Join-Path $programFilesX86 'Windows Kits\10\Redist\D3D\x64'
    )
    Add-CandidateDirectory -List $directories -Path (
      Join-Path $programFilesX86 'Windows Kits\8.1\Redist\D3D\x64'
    )
  }
  if ($env:WINDIR) {
    Add-CandidateDirectory -List $directories -Path (Join-Path $env:WINDIR 'Sysnative')
    Add-CandidateDirectory -List $directories -Path (Join-Path $env:WINDIR 'System32')
  }
  if ($env:SystemRoot) {
    Add-CandidateDirectory -List $directories -Path (Join-Path $env:SystemRoot 'Sysnative')
    Add-CandidateDirectory -List $directories -Path (Join-Path $env:SystemRoot 'System32')
  }

  return $directories.ToArray()
}

function Find-DependencyFile {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string[]]$Directories,
    [switch]$RequireX64
  )

  foreach ($directory in $Directories) {
    $path = Join-Path $directory $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      continue
    }
    if ($RequireX64 -and -not (Test-X64PeFile -Path $path)) {
      Write-Warning "Skipping non-x64 dependency candidate: $path"
      continue
    }
    return $path
  }
  return $null
}

function Copy-PortableDependency {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string[]]$Directories,
    [Parameter(Mandatory = $true)][string]$DestinationDirectory,
    [switch]$RequireX64,
    [string]$InstallHint
  )

  $destination = Join-Path $DestinationDirectory $Name
  if (Test-Path -LiteralPath $destination -PathType Leaf) {
    if ($RequireX64 -and -not (Test-X64PeFile -Path $destination)) {
      throw "Bundled dependency is not x64: $destination"
    }
    Write-Host "[RUNTIME] Found $Name"
    return
  }

  $source = Find-DependencyFile -Name $Name -Directories $Directories `
    -RequireX64:$RequireX64
  if (-not $source) {
    $searched = ($Directories | ForEach-Object { "  $_" }) -join "`r`n"
    throw @"
Required portable dependency was not found: $Name

Searched:
$searched

$InstallHint
"@
  }

  Copy-Item -LiteralPath $source -Destination $destination -Force
  Write-Host "[RUNTIME] Bundled $Name from $source"
}

function Add-PortableRuntimeFiles {
  $runtimeDirs = Get-PortableRuntimeSearchDirectories
  foreach ($dll in $runtimeDlls) {
    Copy-PortableDependency -Name $dll -Directories $runtimeDirs `
      -DestinationDirectory $releaseDir -RequireX64 `
      -InstallHint 'Install Visual Studio 2022 with the C++ desktop workload, or install the Microsoft Visual C++ Redistributable 2015-2022 x64 on the build machine.'
    Copy-PortableDependency -Name $dll -Directories $runtimeDirs `
      -DestinationDirectory $binDir -RequireX64 `
      -InstallHint 'Install Visual Studio 2022 with the C++ desktop workload, or install the Microsoft Visual C++ Redistributable 2015-2022 x64 on the build machine.'
  }

  $d3dDirs = Get-D3DCompilerSearchDirectories
  Copy-PortableDependency -Name 'd3dcompiler_47.dll' -Directories $d3dDirs `
    -DestinationDirectory $binDir -RequireX64 `
    -InstallHint 'Install the Windows 10/11 SDK, or copy the x64 d3dcompiler_47.dll into this project runtime directory before packaging.'
}

function Install-LauncherLayout {
  $flutterExe = Join-Path $releaseDir 'ssrvpn_windows.exe'
  $childExe = Join-Path $binDir 'ssrvpn_windows_app.exe'
  $launcherExe = Join-Path $releaseDir 'ssrvpn_windows_launcher.exe'

  if (-not (Test-Path -LiteralPath $flutterExe -PathType Leaf)) {
    throw "Built Flutter executable was not found: $flutterExe"
  }
  if (-not (Test-Path -LiteralPath $launcherExe -PathType Leaf)) {
    throw "Built portable launcher was not found: $launcherExe"
  }

  if (-not (Test-Path -LiteralPath $binDir -PathType Container)) {
    New-Item -ItemType Directory -Path $binDir | Out-Null
  }
  if (Test-Path -LiteralPath $childExe -PathType Leaf) {
    Remove-Item -LiteralPath $childExe -Force
  }
  Move-Item -LiteralPath $flutterExe -Destination $childExe
  Copy-Item -LiteralPath $launcherExe -Destination $flutterExe -Force
  Remove-Item -LiteralPath $launcherExe -Force
  Write-Host '[LAUNCHER] Installed portable launcher.'
}

function Move-PortableInternalsToBin {
  if (-not (Test-Path -LiteralPath $binDir -PathType Container)) {
    New-Item -ItemType Directory -Path $binDir | Out-Null
  }

  $rootFilesToKeep = @(
    'ssrvpn_windows.exe',
    'SSRVPN_Diag.bat',
    'ssrvpn_safe_mode.bat',
    'SAFE_MODE_README.txt',
    $portableReadmeName,
    'remove_legacy_cet_exemption.ps1',
    'remove_legacy_cet_exemption.bat',
    'SHA256SUMS.txt'
  ) + $runtimeDlls

  Get-ChildItem -LiteralPath $releaseDir -Force | ForEach-Object {
    if ($_.Name -eq 'bin' -or $rootFilesToKeep -contains $_.Name) {
      return
    }
    Move-Item -LiteralPath $_.FullName -Destination (
      Join-Path $binDir $_.Name
    ) -Force
  }
}

function Resolve-FlutterExecutable {
  if ($FlutterExe -and $FlutterExe.Trim().Length -gt 0) {
    if (Test-Path -LiteralPath $FlutterExe -PathType Leaf) {
      return [System.IO.Path]::GetFullPath($FlutterExe)
    }
    $explicitCommand = Get-Command $FlutterExe -ErrorAction SilentlyContinue
    if ($explicitCommand) {
      return $explicitCommand.Source
    }
    throw "Flutter executable was not found: $FlutterExe"
  }

  $pathCommand = Get-Command flutter -ErrorAction SilentlyContinue
  if ($pathCommand) {
    return $pathCommand.Source
  }

  $candidates = @()
  if ($env:FLUTTER_EXE) {
    $candidates += $env:FLUTTER_EXE
  }
  if ($env:FLUTTER_ROOT) {
    $candidates += (Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat')
  }
  $candidates += @(
    (Join-Path $projectRoot '..\flutter\bin\flutter.bat'),
    (Join-Path $projectRoot '..\..\flutter\bin\flutter.bat'),
    (Join-Path $env:USERPROFILE 'flutter\bin\flutter.bat'),
    'C:\src\flutter\bin\flutter.bat',
    'C:\flutter\bin\flutter.bat',
    'D:\flutter\bin\flutter.bat'
  )

  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return [System.IO.Path]::GetFullPath($candidate)
    }
  }

  throw @'
Flutter SDK was not found.

Install Flutter for Windows, then reopen this terminal and run:
  flutter doctor

Common fixes:
  1. Download Flutter SDK and extract it, for example to C:\src\flutter
  2. Add C:\src\flutter\bin to your user PATH
  3. Install Visual Studio 2022 with "Desktop development with C++"
  4. Run build_release.bat again

If Flutter is already installed, run this command instead:
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tool\package_windows.ps1 -FlutterExe "C:\path\to\flutter\bin\flutter.bat"
'@
}

function Set-PubEnvironment {
  param(
    [string]$HostedUrl,
    [string]$StorageUrl
  )

  if ($HostedUrl -and $HostedUrl.Trim().Length -gt 0) {
    $env:PUB_HOSTED_URL = $HostedUrl
  } else {
    $env:PUB_HOSTED_URL = $originalPubHostedUrl
  }

  if ($StorageUrl -and $StorageUrl.Trim().Length -gt 0) {
    $env:FLUTTER_STORAGE_BASE_URL = $StorageUrl
  } else {
    $env:FLUTTER_STORAGE_BASE_URL = $originalFlutterStorageBaseUrl
  }
}

function Restore-PubEnvironment {
  $env:PUB_HOSTED_URL = $originalPubHostedUrl
  $env:FLUTTER_STORAGE_BASE_URL = $originalFlutterStorageBaseUrl
}

function Add-PubAttempt {
  param(
    [System.Collections.ArrayList]$Attempts,
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$HostedUrl,
    [string]$StorageUrl,
    [switch]$Offline
  )

  if ($null -eq $Attempts) {
    throw 'Internal error: pub attempt list was not initialized.'
  }

  [void]$Attempts.Add([pscustomobject]@{
      Name = $Name
      HostedUrl = $HostedUrl
      StorageUrl = $StorageUrl
      Offline = [bool]$Offline
    })
}

function New-PubGetAttempts {
  $attempts = New-Object System.Collections.ArrayList

  if ($OfflinePub) {
    Add-PubAttempt -Attempts $attempts -Name 'offline pub cache' `
      -HostedUrl $env:PUB_HOSTED_URL `
      -StorageUrl $env:FLUTTER_STORAGE_BASE_URL `
      -Offline
  }

  if ($PubHostedUrl -or $FlutterStorageBaseUrl) {
    Add-PubAttempt -Attempts $attempts -Name 'custom pub mirror' `
      -HostedUrl $PubHostedUrl `
      -StorageUrl $FlutterStorageBaseUrl
    return $attempts.ToArray()
  }

  if ($ChinaMirror) {
    Add-PubAttempt -Attempts $attempts -Name 'Flutter China mirror' `
      -HostedUrl $defaultChinaPubHostedUrl `
      -StorageUrl $defaultChinaFlutterStorageBaseUrl
    return $attempts.ToArray()
  }

  Add-PubAttempt -Attempts $attempts -Name 'current/default pub source' `
    -HostedUrl $env:PUB_HOSTED_URL `
    -StorageUrl $env:FLUTTER_STORAGE_BASE_URL

  $alreadyUsingChinaMirror =
    $env:PUB_HOSTED_URL -eq $defaultChinaPubHostedUrl -and
    $env:FLUTTER_STORAGE_BASE_URL -eq $defaultChinaFlutterStorageBaseUrl
  if (-not $NoMirrorFallback -and -not $alreadyUsingChinaMirror) {
    Add-PubAttempt -Attempts $attempts -Name 'Flutter China mirror fallback' `
      -HostedUrl $defaultChinaPubHostedUrl `
      -StorageUrl $defaultChinaFlutterStorageBaseUrl
  }

  return $attempts.ToArray()
}

function Invoke-FlutterPubGet {
  param([Parameter(Mandatory = $true)][string]$Flutter)

  $failures = New-Object 'System.Collections.Generic.List[string]'
  foreach ($attempt in (New-PubGetAttempts)) {
    Set-PubEnvironment -HostedUrl $attempt.HostedUrl `
      -StorageUrl $attempt.StorageUrl

    $arguments = @('pub', 'get')
    if ($attempt.Offline) {
      $arguments += '--offline'
    }

    Write-Host "[PUB] flutter $($arguments -join ' ') ($($attempt.Name))"
    if ($env:PUB_HOSTED_URL) {
      Write-Host "[PUB] PUB_HOSTED_URL=$env:PUB_HOSTED_URL"
    }
    if ($env:FLUTTER_STORAGE_BASE_URL) {
      Write-Host "[PUB] FLUTTER_STORAGE_BASE_URL=$env:FLUTTER_STORAGE_BASE_URL"
    }

    & $Flutter @arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
      Write-Host "[PUB] Dependencies are ready."
      return
    }

    [void]$failures.Add("$($attempt.Name): exit code $exitCode")
    Write-Warning "flutter pub get failed during $($attempt.Name)."
  }

  $failureText = ($failures | ForEach-Object { "  $_" }) -join "`r`n"
  throw @"
flutter pub get failed.

Attempts:
$failureText

This is usually a network problem, not a code problem.
Try one of these fixes on the build machine:
  1. Check that the computer can open https://pub.dev/ in a browser.
  2. If you are in mainland China, run build_release.bat again; the script
     already retries with:
       PUB_HOSTED_URL=$defaultChinaPubHostedUrl
       FLUTTER_STORAGE_BASE_URL=$defaultChinaFlutterStorageBaseUrl
  3. If your network requires a proxy, set HTTPS_PROXY/HTTP_PROXY first.
  4. If all packages are already cached, run:
       build_release.bat -OfflinePub
"@
}

function Test-ReleaseContents {
  param([Parameter(Mandatory = $true)][string]$Root)

  $rootExeFiles = @(Get-ChildItem -LiteralPath $Root -File -Filter '*.exe')
  if ($rootExeFiles.Count -ne 1 -or $rootExeFiles[0].Name -ne 'ssrvpn_windows.exe') {
    $names = ($rootExeFiles | ForEach-Object { $_.Name }) -join ', '
    throw "Portable root must contain exactly one user-facing exe: $names"
  }

  foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $Root $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Required release file is missing: $relativePath"
    }
    if ((Get-Item -LiteralPath $path).Length -le 0) {
      throw "Required release file is empty: $relativePath"
    }
  }

  $peFiles = @(
    'ssrvpn_windows.exe',
    'bin\ssrvpn_windows_app.exe',
    'bin\mihomo.exe',
    'bin\flutter_windows.dll',
    'bin\screen_retriever_windows_plugin.dll',
    'bin\system_tray_plugin.dll',
    'bin\window_manager_plugin.dll',
    'bin\d3dcompiler_47.dll'
  ) + $runtimeDlls + ($runtimeDlls | ForEach-Object { "bin\$_" })
  foreach ($relativePath in $peFiles) {
    $path = Join-Path $Root $relativePath
    if (-not (Test-X64PeFile -Path $path)) {
      throw "Release file is not a valid x64 PE binary: $relativePath"
    }
  }

  $launcher = Join-Path $Root 'ssrvpn_windows.exe'
  $launcherCharacteristics = Get-PeDllCharacteristics -Path $launcher
  if ($null -eq $launcherCharacteristics) {
    throw 'Could not read launcher PE security flags.'
  }
  if (($launcherCharacteristics -band 0x1000) -ne 0) {
    throw 'Launcher unexpectedly requires AppContainer.'
  }
  if (($launcherCharacteristics -band 0x4000) -eq 0) {
    throw 'Launcher is missing the Guard CF PE flag.'
  }

  $core = Join-Path $Root 'bin\mihomo.exe'
  $coreOutput = & $core -v 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Bundled Mihomo failed to execute: $coreOutput"
  }
  if (($coreOutput | Out-String) -notmatch 'Mihomo Meta') {
    throw "Bundled Mihomo returned an unexpected version response: $coreOutput"
  }
}

function Test-ReleaseHashes {
  param([Parameter(Mandatory = $true)][string]$Root)

  $hashFile = Join-Path $Root 'SHA256SUMS.txt'
  if (-not (Test-Path -LiteralPath $hashFile -PathType Leaf)) {
    throw "Release hash manifest is missing: $hashFile"
  }

  foreach ($line in Get-Content -LiteralPath $hashFile -Encoding UTF8) {
    if ($line -notmatch '^([0-9A-Fa-f]{64})  (.+)$') {
      throw "Invalid SHA256SUMS line: $line"
    }
    $expectedHash = $matches[1].ToUpperInvariant()
    $relativePath = $matches[2]
    $file = Join-Path $Root $relativePath
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
      throw "Hashed release file is missing: $relativePath"
    }
    $actualHash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash) {
      throw "Release hash mismatch: $relativePath"
    }
  }
}

function Repair-WindowsPluginLinks {
  param([Parameter(Mandatory = $true)][string]$Root)

  $dependenciesPath = Join-Path $Root '.flutter-plugins-dependencies'
  if (-not (Test-Path -LiteralPath $dependenciesPath -PathType Leaf)) {
    throw "Flutter plugin metadata not found: $dependenciesPath"
  }

  $metadata = Get-Content -LiteralPath $dependenciesPath -Raw |
    ConvertFrom-Json
  $plugins = @($metadata.plugins.windows)
  $linksDir = [System.IO.Path]::GetFullPath(
    (Join-Path $Root 'windows\flutter\ephemeral\.plugin_symlinks')
  )
  $expectedLinksDir = [System.IO.Path]::GetFullPath(
    (Join-Path $projectRoot 'windows\flutter\ephemeral\.plugin_symlinks')
  )
  if ($linksDir -ne $expectedLinksDir) {
    throw "Refusing to replace unexpected plugin directory: $linksDir"
  }

  if (Test-Path -LiteralPath $linksDir) {
    Remove-Item -LiteralPath $linksDir -Recurse -Force
  }
  New-Item -ItemType Directory -Path $linksDir | Out-Null

  foreach ($plugin in $plugins) {
    $linkPath = Join-Path $linksDir $plugin.name
    $targetPath = $plugin.path.TrimEnd('\')
    try {
      New-Item -ItemType SymbolicLink -Path $linkPath -Target $targetPath `
        -ErrorAction Stop | Out-Null
    } catch [System.UnauthorizedAccessException] {
      New-Item -ItemType Junction -Path $linkPath -Target $targetPath `
        -ErrorAction Stop | Out-Null
    }
  }
}

Push-Location $projectRoot
try {
  if (-not $SkipBuild) {
    $flutter = Resolve-FlutterExecutable
    Write-Host "[BUILD] Flutter: $flutter"
    $previousParallelLevel = $env:CMAKE_BUILD_PARALLEL_LEVEL
    $lockPath = Join-Path $projectRoot 'pubspec.lock'
    $lockExisted = Test-Path -LiteralPath $lockPath -PathType Leaf
    [byte[]]$lockBytes = $null
    if ($lockExisted) {
      $lockBytes = [System.IO.File]::ReadAllBytes($lockPath)
    }
    try {
      # New MSVC toolsets occasionally fail in STL headers under highly
      # parallel Flutter builds. A single build worker favors reproducibility.
      $env:CMAKE_BUILD_PARALLEL_LEVEL = '1'
      Invoke-FlutterPubGet -Flutter $flutter
      Repair-WindowsPluginLinks -Root $projectRoot
      & $flutter build windows --release --no-pub
      if ($LASTEXITCODE -ne 0) {
        throw "flutter build failed with exit code $LASTEXITCODE"
      }
    } finally {
      $env:CMAKE_BUILD_PARALLEL_LEVEL = $previousParallelLevel
      if ($lockExisted) {
        [System.IO.File]::WriteAllBytes($lockPath, $lockBytes)
      } elseif (Test-Path -LiteralPath $lockPath) {
        Remove-Item -LiteralPath $lockPath -Force
      }
    }
  }

  if (-not (Test-Path -LiteralPath $buildDir -PathType Container)) {
    throw "Release build directory not found: $buildDir"
  }

  $expectedReleaseDir = [System.IO.Path]::GetFullPath(
    (Join-Path $projectRoot 'SSRVPN_Windows_Release')
  )
  if ([System.IO.Path]::GetFullPath($releaseDir) -ne $expectedReleaseDir) {
    throw "Refusing to clean unexpected release directory: $releaseDir"
  }

  if (Test-Path -LiteralPath $releaseDir) {
    Remove-Item -LiteralPath $releaseDir -Recurse -Force
  }
  New-Item -ItemType Directory -Path $releaseDir | Out-Null
  Copy-Item -Path (Join-Path $buildDir '*') -Destination $releaseDir `
    -Recurse -Force

  Install-LauncherLayout
  Add-PortableRuntimeFiles

  $portableReadmeName = [string]::Concat(
    [char]0x4F7F,
    [char]0x7528,
    [char]0x6559,
    [char]0x7A0B,
    '.txt'
  )
  # Diagnostic launcher script
  Copy-Item -LiteralPath (Join-Path $projectRoot 'SSRVPN_Diag.bat') `
    -Destination (Join-Path $releaseDir 'SSRVPN_Diag.bat')
  # Safe mode launcher
  Copy-Item -LiteralPath (Join-Path $projectRoot 'ssrvpn_safe_mode.bat') `
    -Destination (Join-Path $releaseDir 'ssrvpn_safe_mode.bat')
  # Readme files
  Copy-Item -LiteralPath (Join-Path $projectRoot 'SAFE_MODE_README.txt') `
    -Destination (Join-Path $releaseDir 'SAFE_MODE_README.txt')
  Copy-PortableReadme -Destination (Join-Path $releaseDir $portableReadmeName)
  # One-time cleanup for security exceptions created by older releases.
  Copy-Item -LiteralPath (Join-Path $projectRoot 'scripts\remove_legacy_cet_exemption.ps1') `
    -Destination (Join-Path $releaseDir 'remove_legacy_cet_exemption.ps1')
  Copy-Item -LiteralPath (Join-Path $projectRoot 'scripts\remove_legacy_cet_exemption.bat') `
    -Destination (Join-Path $releaseDir 'remove_legacy_cet_exemption.bat')

  Move-PortableInternalsToBin
  Test-ReleaseContents -Root $releaseDir

  if ($env:WINDOWS_SIGNING_ENABLED -eq 'true') {
    $signingScript = Join-Path $projectRoot '..\scripts\sign_windows_artifacts.ps1'
    & $signingScript -FilePath @(
      (Join-Path $releaseDir 'ssrvpn_windows.exe'),
      (Join-Path $releaseDir 'bin\ssrvpn_windows_app.exe')
    )
    if ($LASTEXITCODE -ne 0) {
      throw "Windows portable signing failed with exit code $LASTEXITCODE"
    }
  }

  $releasePrefix = [System.IO.Path]::GetFullPath($releaseDir).TrimEnd('\') + '\'
  $hashLines = Get-ChildItem -LiteralPath $releaseDir -Recurse -File |
    Where-Object { $_.Name -ne 'SHA256SUMS.txt' } |
    Sort-Object FullName |
    ForEach-Object {
      $hash = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
      $fullName = [System.IO.Path]::GetFullPath($_.FullName)
      if (-not $fullName.StartsWith(
        $releasePrefix,
        [System.StringComparison]::OrdinalIgnoreCase
      )) {
        throw "Release file is outside the expected directory: $fullName"
      }
      $relativePath = $fullName.Substring($releasePrefix.Length)
      "$($hash.Hash)  $relativePath"
    }
  $hashLines | Set-Content -LiteralPath (
    Join-Path $releaseDir 'SHA256SUMS.txt'
  ) -Encoding UTF8
  Test-ReleaseHashes -Root $releaseDir

  if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
  }
  if (Test-Path -LiteralPath $zipHashPath) {
    Remove-Item -LiteralPath $zipHashPath -Force
  }
  Compress-Archive -LiteralPath $releaseDir -DestinationPath $zipPath `
    -CompressionLevel Optimal

  $verifyRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
  ) "SSRVPN-package-verify-$([Guid]::NewGuid().ToString('N'))"
  try {
    Expand-Archive -LiteralPath $zipPath -DestinationPath $verifyRoot
    $verifiedReleaseDir = Join-Path $verifyRoot 'SSRVPN_Windows_Release'
    Test-ReleaseContents -Root $verifiedReleaseDir
    Test-ReleaseHashes -Root $verifiedReleaseDir
  } finally {
    $expectedTempRoot = [System.IO.Path]::GetFullPath(
      [System.IO.Path]::GetTempPath()
    )
    $resolvedVerifyRoot = [System.IO.Path]::GetFullPath($verifyRoot)
    if (-not $resolvedVerifyRoot.StartsWith(
      $expectedTempRoot,
      [System.StringComparison]::OrdinalIgnoreCase
    )) {
      throw "Refusing to clean unexpected verification directory: $verifyRoot"
    }
    if (Test-Path -LiteralPath $resolvedVerifyRoot) {
      Remove-Item -LiteralPath $resolvedVerifyRoot -Recurse -Force
    }
  }

  $zipHash = Get-FileHash -LiteralPath $zipPath -Algorithm SHA256
  [System.IO.File]::WriteAllText(
    $zipHashPath,
    "$($zipHash.Hash.ToLower())  SSRVPN.zip`n",
    [System.Text.Encoding]::ASCII
  )
  Write-Host "Release: $releaseDir"
  Write-Host "ZIP:     $zipPath"
  Write-Host "ZIP hash:$zipHashPath"
  Write-Host "SHA256:  $($zipHash.Hash)"
} finally {
  Pop-Location
  Restore-PubEnvironment
  if ($transcriptStarted) {
    try {
      Stop-Transcript | Out-Null
    } catch {
    }
  }
}
