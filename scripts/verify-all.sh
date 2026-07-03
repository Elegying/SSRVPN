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

run_step "Shared pub get" run_in packages/ssrvpn_shared dart pub get
run_step "Shared analyze" run_in packages/ssrvpn_shared dart analyze
run_step "Shared tests" run_in packages/ssrvpn_shared dart test --coverage=coverage

for app in SSRVPN_Android SSRVPN_MacOS SSRVPN_Windows; do
  run_step "$app pub get" run_in "$app" flutter pub get
  run_step "$app analyze" run_in "$app" flutter analyze
  run_step "$app tests" run_in "$app" flutter test --coverage
done

echo
echo "All verification commands completed."
