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

run_step "Shared pub get" run_in packages/ssrvpn_shared dart pub get
run_step "Shared analyze" run_in packages/ssrvpn_shared dart analyze
run_step "Shared tests" run_in packages/ssrvpn_shared dart test

for app in SSRVPN_Android SSRVPN_MacOS SSRVPN_Windows; do
  run_step "$app pub get" run_in "$app" flutter pub get
  run_step "$app analyze" run_in "$app" flutter analyze
  run_step "$app tests" run_in "$app" flutter test
done

echo
echo "All verification commands completed."
