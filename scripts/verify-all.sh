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
run_step "Package guides" scripts/check-package-guides.sh
run_step "Documentation consistency" scripts/check-doc-consistency.sh
run_step "Core asset bootstrap model" scripts/check-core-asset-bootstrap.sh
run_step "Core asset bootstrap" scripts/bootstrap-core-assets.sh
run_step "Core binary assets" scripts/verify-core-assets.sh
run_step "Android native bridge guards" scripts/check-android-native-bridge-guards.sh
run_step "Unlock audit cancellation guards" scripts/check-unlock-test-guards.sh
run_step "Desktop startup guards" scripts/check-desktop-startup-guards.sh
run_step "Clash service boundaries" bash scripts/check-clash-service-boundaries.sh
run_step "Desktop secure storage guards" scripts/check-desktop-secure-storage.sh
run_step "macOS core privilege guards" scripts/check-macos-core-privileges.sh
run_step "Windows launcher security" scripts/check-windows-launcher-security.sh
run_step "Secret scan" scripts/check-secrets.sh
run_step "Release tooling tests" python3 -m unittest \
  scripts/test_generate_release_notes.py \
  scripts/test_generate_oss_release_manifest.py \
  scripts/test_generate_release_provenance.py \
  scripts/test_verify_release_transition.py \
  scripts/test_promote_oss_public_channel.py \
  scripts/test_reuse_github_release_assets.py \
  scripts/test_validate_existing_release_retry.py \
  scripts/test_run_command_with_timeout.py \
  scripts/test_windows_installer_config.py \
  scripts/test_windows_proxy_shutdown_recovery.py

run_step "Workspace pub get" flutter pub get
run_step "Workspace analyze" flutter analyze
run_step "Shared tests" run_in packages/ssrvpn_shared flutter test --coverage
run_step "Shared coverage thresholds" \
  scripts/check-coverage-thresholds.sh packages/ssrvpn_shared

for app in SSRVPN_Android SSRVPN_MacOS SSRVPN_Windows; do
  run_step "$app tests" run_in "$app" flutter test --coverage
  if [[ "$app" == "SSRVPN_Android" ]]; then
    run_step "Android native unit tests" scripts/test-android-native.sh
  fi
  run_step "$app coverage thresholds" scripts/check-coverage-thresholds.sh "$app"
done

echo
echo "All verification commands completed."
