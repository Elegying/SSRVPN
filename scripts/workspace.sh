#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SHARED_PACKAGES=(packages/ssrvpn_shared)
FLUTTER_APPS=(SSRVPN_Android SSRVPN_MacOS SSRVPN_Windows)
PACKAGES=("${SHARED_PACKAGES[@]}" "${FLUTTER_APPS[@]}")

usage() {
  cat <<'USAGE'
Usage: scripts/workspace.sh <command>

Commands:
  pub-get   Fetch dependencies for the workspace
  deps      Alias for pub-get
  analyze   Run analyzer across the workspace
  test      Run tests across every workspace package
  format    Format lib/ and test/ in every package
  verify    Run the full repository verification script
USAGE
}

run_in() {
  local dir="$1"
  shift
  echo
  echo "==> $dir: $*"
  (cd "$ROOT/$dir" && "$@")
}

case "${1:-}" in
  pub-get | deps)
    run_in . flutter pub get
    ;;
  analyze)
    # Analyze each handwritten Dart source root explicitly. A root workspace
    # analysis also indexes generated/native build trees and can leave the Dart
    # language server spinning without producing diagnostics.
    for package in "${SHARED_PACKAGES[@]}"; do
      run_in "$package" flutter analyze lib test tool
    done
    for app in "${FLUTTER_APPS[@]}"; do
      run_in "$app" flutter analyze lib test
    done
    ;;
  test)
    run_in . flutter pub get
    for package in "${SHARED_PACKAGES[@]}"; do
      run_in "$package" flutter test
    done
    for app in "${FLUTTER_APPS[@]}"; do
      run_in "$app" flutter test
    done
    ;;
  format)
    for package in "${PACKAGES[@]}"; do
      run_in "$package" dart format lib test
    done
    ;;
  verify)
    "$ROOT/scripts/verify-all.sh"
    ;;
  -h | --help | help)
    usage
    ;;
  *)
    usage
    exit 64
    ;;
esac
