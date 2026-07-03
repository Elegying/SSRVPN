#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/SsrvpnVpnService.kt"
MAIN_ACTIVITY="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/MainActivity.kt"

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
require_activity_text '"flutter.autoConnectOnStartup"'

echo "Android native bridge guard check passed."
