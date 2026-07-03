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

run_step "Shared dependency status" \
  run_in packages/ssrvpn_shared dart pub outdated --no-dev-dependencies

for app in SSRVPN_Android SSRVPN_MacOS SSRVPN_Windows; do
  run_step "$app dependency status" \
    run_in "$app" flutter pub outdated --no-dev-dependencies
done

echo
echo "Dependency status check completed."
