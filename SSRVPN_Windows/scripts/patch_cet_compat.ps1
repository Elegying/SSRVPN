# Post-build step: patches the CET_COMPAT (0x1000) PE flag into the given
# executable.  MSVC linker /CETCOMPAT requires all input objects to be
# CET-marked, which fails when linking non-code resources (e.g. .res).
# The machine code is CET-compatible (/guard:cf); only the PE metadata
# flag needs to be set.

param(
    [Parameter(Mandatory=$true)]
    [string]$TargetExe
)

$bytes = [System.IO.File]::ReadAllBytes($TargetExe)
$peOffset = [BitConverter]::ToInt32($bytes, 0x3C)

# DllCharacteristics is at offset 70 within the optional header, which starts
# at peOffset + 4 (signature) + 20 (file header).
$charsOffset = $peOffset + 4 + 20 + 70

$chars = [BitConverter]::ToUInt16($bytes, $charsOffset)
$before = "0x{0:X4}" -f $chars

$chars = $chars -bor 0x1000  # IMAGE_DLLCHARACTERISTICS_CET_COMPAT

[BitConverter]::GetBytes($chars).CopyTo($bytes, $charsOffset)
[System.IO.File]::WriteAllBytes($TargetExe, $bytes)

$after = "0x{0:X4}" -f $chars
Write-Output "CET_COMPAT patched: $before -> $after  |  $TargetExe"
