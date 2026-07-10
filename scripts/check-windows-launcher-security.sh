#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

launcher="SSRVPN_Windows/windows/runner/launcher_main.cpp"
package_script="SSRVPN_Windows/tool/package_windows.ps1"
windows_cmake="SSRVPN_Windows/windows/CMakeLists.txt"
cleanup_script="SSRVPN_Windows/scripts/remove_legacy_cet_exemption.ps1"

for forbidden in \
  'Set-ProcessMitigation' \
  'UserShadowStack' \
  'kCetDisableMask' \
  'PROC_THREAD_ATTRIBUTE_MITIGATION_POLICY' \
  'ssrvpn_cet_fix'; do
  if rg -n --fixed-strings "$forbidden" \
    "$launcher" "$package_script" "$windows_cmake" >/dev/null; then
    echo "Windows launcher security guard failed: found $forbidden" >&2
    exit 1
  fi
done

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

rg -q --fixed-strings '::CreateProcessW(' "$launcher"
rg -q --fixed-strings \
  'Set-ProcessMitigation -Name $name -Remove -Disable UserShadowStack' \
  "$cleanup_script"
if rg -n 'New-Item(Property)?[^\n]*DisableUserShadowStack' \
  "$cleanup_script" >/dev/null; then
  echo "Windows launcher security guard failed: cleanup script writes an exemption" >&2
  exit 1
fi
echo "Windows launcher security guards passed."
