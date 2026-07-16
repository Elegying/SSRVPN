#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

launcher="SSRVPN_Windows/windows/runner/launcher_main.cpp"
package_script="SSRVPN_Windows/tool/package_windows.ps1"
windows_cmake="SSRVPN_Windows/windows/CMakeLists.txt"
runner_cmake="SSRVPN_Windows/windows/runner/CMakeLists.txt"
cleanup_script="SSRVPN_Windows/scripts/remove_legacy_cet_exemption.ps1"
cleanup_launcher="SSRVPN_Windows/scripts/remove_legacy_cet_exemption.bat"
diagnostic_launcher="SSRVPN_Windows/SSRVPN_Diag.bat"
startup_diagnostics="SSRVPN_Windows/windows/runner/startup_diagnostics.cpp"

for forbidden in \
  'Set-ProcessMitigation' \
  'UserShadowStack' \
  'kCetDisableMask' \
  'PROC_THREAD_ATTRIBUTE_MITIGATION_POLICY' \
  'ssrvpn_cet_fix'; do
  if grep -n -F -- "$forbidden" \
    "$launcher" "$package_script" "$windows_cmake" >/dev/null; then
    echo "Windows launcher security guard failed: found $forbidden" >&2
    exit 1
  fi
done

for forbidden in \
  'BitConverter]::ToUInt16' \
  '-bor 0x1000' \
  'Patching CET_COMPAT PE flag'; do
  if grep -n -F -- "$forbidden" "$runner_cmake" >/dev/null; then
    echo "Windows launcher security guard failed: found invalid PE patch: $forbidden" >&2
    exit 1
  fi
done

grep -Fq 'target_compile_options(${LAUNCHER_TARGET} PRIVATE "/guard:cf")' \
  "$runner_cmake"
grep -Fq \
  'target_link_options(${LAUNCHER_TARGET} PRIVATE "/CETCOMPAT" "/GUARD:CF")' \
  "$runner_cmake"

for obsolete in \
  SSRVPN_Windows/scripts/ssrvpn_cet_fix.ps1 \
  SSRVPN_Windows/scripts/ssrvpn_cet_fix.bat \
  SSRVPN_Windows/scripts/installer_cet_snippet.nsi \
  SSRVPN_Windows/scripts/patch_cet_compat.ps1; do
  if [[ -e "$obsolete" ]]; then
    echo "Windows launcher security guard failed: obsolete file remains: $obsolete" >&2
    exit 1
  fi
done

grep -Fq '::CreateProcessW(' "$launcher"
grep -Fq \
  'Set-ProcessMitigation -Name $name -Remove -Disable UserShadowStack' \
  "$cleanup_script"
if grep -E -n 'New-Item(Property)?.*DisableUserShadowStack' \
  "$cleanup_script" >/dev/null; then
  echo "Windows launcher security guard failed: cleanup script writes an exemption" >&2
  exit 1
fi
if grep -E -n 'Remove-ItemProperty.*-ErrorAction SilentlyContinue' \
  "$cleanup_script" >/dev/null; then
  echo "Windows launcher security guard failed: cleanup hides registry errors" >&2
  exit 1
fi
grep -Fq "Remove-ItemProperty -LiteralPath \$legacyPath" \
  "$cleanup_script"
grep -Fq "Get-ItemProperty -LiteralPath \$legacyPath" \
  "$cleanup_script"
grep -Fq 'exit /b %EXIT_CODE%' "$cleanup_launcher"
grep -Fq 'remove_legacy_cet_exemption.bat' "$diagnostic_launcher"
grep -Fq 'function Get-PeDllCharacteristics' "$package_script"
grep -Fq 'Launcher unexpectedly requires AppContainer' \
  "$package_script"
grep -Fq 'Launcher is missing the Guard CF PE flag' \
  "$package_script"
if grep -n -F 'AddVectoredExceptionHandler' \
  "$startup_diagnostics" >/dev/null; then
  echo "Windows launcher security guard failed: first-chance dump handler remains" >&2
  exit 1
fi
grep -Fq 'SetUnhandledExceptionFilter' "$startup_diagnostics"
grep -Fq 'kMaxCrashDumps = 5' "$startup_diagnostics"
grep -Fq 'PruneCrashDumps' "$startup_diagnostics"
echo "Windows launcher security guards passed."
