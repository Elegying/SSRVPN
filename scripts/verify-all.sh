#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

run_step() {
  local title="$1"
  shift
  echo
  echo "==> $title"
  "$@"
}

run_in() {
  local dir="$1"
  shift
  (cd "$dir" && "$@")
}

run_step "Shared barrel imports" scripts/check-shared-barrel-imports.sh
run_step "Version sync" scripts/check-version-sync.sh
run_step "Core binary assets" scripts/verify-core-assets.sh
run_step "Android native bridge guards" scripts/check-android-native-bridge-guards.sh
run_step "Desktop startup guards" scripts/check-desktop-startup-guards.sh
run_step "macOS core privilege guards" scripts/check-macos-core-privileges.sh
run_step "Windows launcher security" scripts/check-windows-launcher-security.sh
run_step "Secret scan" scripts/check-secrets.sh

run_step "Workspace pub get" flutter pub get
run_step "Workspace analyze" flutter analyze
run_step "Shared tests" run_in packages/ssrvpn_shared flutter test --coverage

for app in SSRVPN_Android SSRVPN_MacOS SSRVPN_Windows; do
  run_step "$app tests" run_in "$app" flutter test --coverage
  if [[ "$app" == "SSRVPN_Android" ]]; then
    run_step "Android native unit tests" scripts/test-android-native.sh
  fi
  run_step "$app coverage thresholds" scripts/check-coverage-thresholds.sh "$app"
done

echo
echo "All verification commands completed."
