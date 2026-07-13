#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

require_text() {
  local path="$1"
  local text="$2"
  if ! grep -Fq -- "$text" "$path"; then
    echo "desktop secure storage guard failed: $path missing $text" >&2
    exit 1
  fi
}

for platform in SSRVPN_MacOS SSRVPN_Windows; do
  settings="$platform/lib/services/settings_service.dart"
  require_text "$settings" "_writeVerifiedApiSecret"
  require_text "$settings" "_replaceVerifiedApiSecret"
  require_text "$settings" "resetAppData() => _saveQueue.add"
  require_text "$settings" "remove('apiSecret')"
done

macos_settings="SSRVPN_MacOS/lib/services/settings_service.dart"
require_text "$macos_settings" ".api-secret"
require_text "$macos_settings" "followLinks: false"
require_text "$macos_settings" "_chmod('600'"
require_text "$macos_settings" "_chmod('700'"
require_text "$macos_settings" "_ensurePrivateDataDirectory"
require_text "$macos_settings" "_removeLegacySharedPreferences"
require_text "$macos_settings" "_syncDataDirectory"
require_text "$macos_settings" "_removeApiSecretTemporaryFiles"

if grep -Fq 'flutter_secure_storage:' SSRVPN_MacOS/pubspec.yaml; then
  echo "desktop secure storage guard failed: ad-hoc macOS releases must not depend on an upgrade-unstable file-keychain ACL" >&2
  exit 1
fi

windows_store="SSRVPN_Windows/lib/services/windows_dpapi_secret_store.dart"
require_text SSRVPN_Windows/pubspec.yaml "ffi:"
require_text SSRVPN_Windows/pubspec.yaml "win32:"
require_text "$windows_store" ".api-secret.dpapi"
require_text "$windows_store" "CryptProtectData"
require_text "$windows_store" "CryptUnprotectData"
require_text "$windows_store" "create(exclusive: true)"
require_text "$windows_store" "MOVEFILE_REPLACE_EXISTING"
require_text "$windows_store" "MOVEFILE_WRITE_THROUGH"
require_text "$windows_store" "followLinks: false"
require_text "$windows_store" "_removeTemporaryFiles"
require_text SSRVPN_Windows/lib/services/settings_service.dart \
  "_apiSecretFileName"
require_text SSRVPN_Windows/installer/prepare_install_directory.ps1 \
  ".api-secret.dpapi"
require_text scripts/test_windows_installer_runtime.ps1 \
  ".api-secret.dpapi"

if grep -Fq 'flutter_secure_storage:' SSRVPN_Windows/pubspec.yaml; then
  echo "desktop secure storage guard failed: Windows secret writes must remain crash-consistent" >&2
  exit 1
fi

for entitlements in \
  SSRVPN_MacOS/macos/Runner/DebugProfile.entitlements \
  SSRVPN_MacOS/macos/Runner/Release.entitlements; do
  if grep -Fq 'keychain-access-groups' "$entitlements"; then
    echo "desktop secure storage guard failed: ad-hoc macOS builds cannot use provisioned keychain access groups" >&2
    exit 1
  fi
done

echo "Desktop secure storage guards passed."
