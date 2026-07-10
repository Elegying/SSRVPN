#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/SsrvpnVpnService.kt"
MAIN_ACTIVITY="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/MainActivity.kt"
TILE_SERVICE="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/VpnTileService.kt"

require_text() {
  local needle="$1"
  if ! grep -Fq "$needle" "$SERVICE"; then
    echo "Android native guard check failed: missing '$needle'" >&2
    exit 1
  fi
}

require_activity_text() {
  local needle="$1"
  if ! grep -Fq "$needle" "$MAIN_ACTIVITY"; then
    echo "Android native MethodChannel check failed: missing '$needle'" >&2
    exit 1
  fi
}

require_tile_text() {
  local needle="$1"
  if ! grep -Fq "$needle" "$TILE_SERVICE"; then
    echo "Android native tile guard check failed: missing '$needle'" >&2
    exit 1
  fi
}

require_count() {
  local needle="$1"
  local expected="$2"
  local count
  count="$(grep -Fo "$needle" "$SERVICE" | wc -l | tr -d '[:space:]')"
  if [ "$count" != "$expected" ]; then
    echo "Android native guard check failed: expected $expected '$needle' call(s), got $count" >&2
    exit 1
  fi
}

require_text "BRIDGE_START_TIMEOUT_MS"
require_text "BRIDGE_STOP_TIMEOUT_MS"
require_text "BRIDGE_IS_RUNNING_TIMEOUT_MS"
require_text "startBridgeWithTimeout"
require_text "stopBridgeWithTimeout"
require_text "isBridgeRunningWithTimeout"
require_text "SSRVPN-bridge-start"
require_text "SSRVPN-bridge-stop"
require_text "SSRVPN-bridge-is-running"

require_count "bridge.Bridge.init(configDir, \"config.yaml\")" 1
require_count "bridge.Bridge.start(configPath, tunFd)" 1
require_count "bridge.Bridge.stop()" 1
require_count "bridge.Bridge.isRunning()" 1

require_activity_text '"syncSettings"'
require_activity_text '"flutter.proxyPort"'
require_activity_text '"installUpdate"'
require_activity_text "Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES"
require_activity_text "PENDING_UPDATE_APK_PATH"
require_activity_text "continuePendingUpdateInstallIfAllowed"
require_activity_text "override fun onResume()"
require_activity_text "FileProvider.getUriForFile"
require_text "ContextCompat.registerReceiver"
require_activity_text "ContextCompat.registerReceiver"
require_tile_text "ContextCompat.registerReceiver"
require_text "ContextCompat.RECEIVER_NOT_EXPORTED"
require_activity_text "ContextCompat.RECEIVER_NOT_EXPORTED"
require_tile_text "ContextCompat.RECEIVER_NOT_EXPORTED"
require_activity_text "vpnPermissionRequestPending"
require_activity_text "startVpnServiceWithTimeout"
require_activity_text "AtomicBoolean(false)"
require_text "Bridge.isRunning already in progress; treating as stopped"
require_text "Bridge.isRunning timed out after"
require_text "treating as stopped"

echo "Android native bridge guard check passed."
