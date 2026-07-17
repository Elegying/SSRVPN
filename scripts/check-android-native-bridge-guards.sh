#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/SsrvpnVpnService.kt"
MAIN_ACTIVITY="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/MainActivity.kt"
TILE_SERVICE="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/VpnTileService.kt"
BUILD_GRADLE="$ROOT/SSRVPN_Android/android/app/build.gradle.kts"
MANIFEST="$ROOT/SSRVPN_Android/android/app/src/main/AndroidManifest.xml"
HOME_DART="$ROOT/SSRVPN_Android/lib/screens/home_screen.dart"
HOME_PARTS=(
  "$ROOT/SSRVPN_Android/lib/screens/home_connection_actions_part.dart"
  "$ROOT/SSRVPN_Android/lib/screens/home_lifecycle_actions_part.dart"
  "$ROOT/SSRVPN_Android/lib/screens/home_node_actions_part.dart"
  "$ROOT/SSRVPN_Android/lib/screens/home_public_ip_part.dart"
)
PUBLIC_ROUTES="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/PublicIpv4Routes.kt"
VPN_ROUTE_INSTALLER="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/VpnRouteInstaller.kt"
NOTIFICATION_SUPPORT="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/VpnNotificationSupport.kt"
CORE_LIVENESS_MONITOR="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/CoreLivenessMonitor.kt"
NATIVE_SNAPSHOT_STORE="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/NativeConnectionSnapshotStore.kt"

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

require_build_text() {
  local needle="$1"
  if ! grep -Fq "$needle" "$BUILD_GRADLE"; then
    echo "Android debug identity check failed: missing '$needle'" >&2
    exit 1
  fi
}

require_manifest_text() {
  local needle="$1"
  if ! grep -Fq "$needle" "$MANIFEST"; then
    echo "Android manifest identity check failed: missing '$needle'" >&2
    exit 1
  fi
}

require_home_text() {
  local needle="$1"
  if ! grep -Fq "$needle" \
    "$HOME_DART" \
    "${HOME_PARTS[@]}"; then
    echo "Android home lifecycle check failed: missing '$needle'" >&2
    exit 1
  fi
}

require_route_text() {
  local needle="$1"
  if ! grep -Fq "$needle" "$VPN_ROUTE_INSTALLER"; then
    echo "Android VPN route guard check failed: missing '$needle'" >&2
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
require_text "PENDING_START_CANCEL_GRACE_MS = 1_000L"
require_text "serviceStartInProgress.compareAndSet(false, true)"
require_text "processTerminationPending.get()"
require_text "processTerminationPending.set(true)"
require_text "startGeneration.invalidate { isRunning = false }"
require_text "startGeneration.runIfCurrent(startToken)"
require_text "ensureStartCurrent(startToken)"
require_text "CoreRecoveryPolicy.nextAttempt(request.attempt)"
require_text "stopForRecovery"
require_text "showCoreRecoveryFailedNotification"
require_text "EXTRA_RECOVERY_ATTEMPT"
require_text "EXTRA_RECOVERY_TOKEN"
require_text "CoreRecoveryPolicy.shouldAcceptRestart("

python3 - "$SERVICE" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
selection = source.index("applyProxySelection(apiPort, apiSecret, selectedNodeName)")
publish = source.index("isRunning = true", selection)
if "startGeneration.runIfCurrent(startToken)" not in source[selection:publish]:
    raise SystemExit("Android VPN publishes connected state outside the atomic generation gate")
PY
require_text "waitForPendingStart()"
require_text "VPN is already running; reusing the active session"
require_text "createStartIntent"
require_text "intent?.getStringExtra(EXTRA_CONFIG_DIR)"
require_text "BRIDGE_STOP_TIMEOUT_MS"
require_text "BRIDGE_IS_RUNNING_TIMEOUT_MS"
require_text "startBridgeWithTimeout"
require_text "stopBridgeWithTimeout"
require_text "isBridgeRunningWithTimeout"
require_text "SSRVPN-bridge-start"
require_text "SSRVPN-bridge-stop"
require_text "SSRVPN-bridge-is-running"
require_text "private fun monitorCoreRunning("
require_text "recoverFromUnexpectedCoreExit("
require_text "ContextCompat.startForegroundService(this, restartIntent)"

require_count "bridge.Bridge.init(configDir, \"config.yaml\")" 1
require_count "bridge.Bridge.start(configPath, tunFd)" 1
require_count "bridge.Bridge.stop()" 1
require_count "bridge.Bridge.isRunning()" 1

require_activity_text '"syncSettings"'
require_activity_text '"clearConnectionSnapshot"'
require_activity_text "private fun handleNativeMethodCall("
require_activity_text "NativeConnectionSnapshotStore.write("
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
require_text "ConcurrentHashMap<String, (Boolean, String) -> Unit>()"
require_tile_text "clearStartResultCallback(requestId)"
require_activity_text "registerStartResultCallback(callback)"
require_tile_text "SsrvpnVpnService.isCoreOperationBusy()"
require_tile_text "SsrvpnVpnService.cancelPendingStart()"
require_tile_text "service.stopAll {"
require_tile_text "isConnected = SsrvpnVpnService.isRunning"
require_tile_text "SsrvpnVpnService.createStartIntent"
require_tile_text "NativeConnectionSnapshotStore.read(this)"
require_activity_text "vpnPermissionRequestPending"
require_activity_text "startVpnServiceWithTimeout"
require_activity_text "pendingVpnServiceIntent"
require_activity_text "SsrvpnVpnService.createStartIntent"
require_activity_text "AtomicBoolean(false)"
require_activity_text "Manifest.permission.POST_NOTIFICATIONS"
require_activity_text "NOTIFICATION_PERMISSION_REQUESTED"
require_activity_text "requestNotificationPermissionOnce"
require_activity_text "Build.VERSION_CODES.TIRAMISU"
require_text "Bridge.isRunning already in progress; deferring verdict"
require_text "Bridge.isRunning timed out after"
require_text "treating as stopped"
require_text "Bridge.stop failed or timed out; terminating process to release the detached TUN fd"
require_text "android.os.Process.killProcess(android.os.Process.myPid())"
require_text "VpnRouteInstaller.configure(builder)"
require_route_text "PublicIpv4Routes.routes"
require_route_text "configure(builder::addAddress, builder::addRoute)"
require_route_text 'addAddress("198.18.0.1", 32)'
require_route_text "VpnIpv6Config.address"
require_route_text "addRoute(route.address, route.prefixLength)"
require_route_text "VpnIpv6Config.defaultRoute"
require_text "VpnNotificationSupport.createChannel(this, CHANNEL_ID)"
require_text "NativeConnectionSnapshotStore.read(this)"
require_text "notificationUpdatePolicy.publishIfChanged(state)"
require_text "Looper.myLooper() != notificationHandler.looper"
require_text "notifyCurrentState(currentNotificationState())"
require_activity_text "NATIVE_SNAPSHOT_UPDATE_FAILED"

if grep -R -n -E 'flutter\.(apiSecret|configDir|configPath|apiPort|selectedNodeName)' \
  "$MAIN_ACTIVITY" "$SERVICE" "$TILE_SERVICE"; then
  echo "Android native snapshot guard failed: split Flutter preferences are still used" >&2
  exit 1
fi
for needle in \
  'AndroidKeyStore' \
  'AES/GCM/NoPadding' \
  'setRandomizedEncryptionRequired(true)'; do
  grep -Fq "$needle" "$NATIVE_SNAPSHOT_STORE" || {
    echo "Android native credential guard failed: missing '$needle'" >&2
    exit 1
  }
done
grep -Fq "fun clear(context: Context)" "$NATIVE_SNAPSHOT_STORE" || {
  echo "Android native snapshot guard failed: clear operation is missing" >&2
  exit 1
}

python3 - "$NATIVE_SNAPSHOT_STORE" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
read_start = source.index("fun read(context: Context)")
read_end = source.index("fun updateSelectedNode", read_start)
if ".remove(" in source[read_start:read_end]:
    raise SystemExit("Android native snapshot read failure still deletes recovery data")
PY

require_build_text 'applicationIdSuffix = ".debug"'
require_build_text 'versionNameSuffix = "-debug"'
require_build_text 'manifestPlaceholders["appLabel"] = "SSRVPN Debug"'
require_manifest_text 'android:label="${appLabel}"'
require_manifest_text 'android:allowBackup="false"'

home_lines="$(wc -l < "$HOME_DART" | tr -d '[:space:]')"
if [ "$home_lines" -gt 500 ]; then
  echo "Android home boundary check failed: home_screen.dart grew to $home_lines lines" >&2
  exit 1
fi
for home_part in "${HOME_PARTS[@]}"; do
  if [ ! -f "$home_part" ]; then
    echo "Android home boundary check failed: missing $home_part" >&2
    exit 1
  fi
  part_lines="$(wc -l < "$home_part" | tr -d '[:space:]')"
  if [ "$part_lines" -gt 500 ]; then
    echo "Android home boundary check failed: $home_part grew to $part_lines lines" >&2
    exit 1
  fi
  part_name="$(basename "$home_part")"
  if ! grep -Fq "part '$part_name';" "$HOME_DART"; then
    echo "Android home boundary check failed: home_screen.dart does not declare $part_name" >&2
    exit 1
  fi
done

require_home_text "clashService.requestConnectionIntent(false)"
require_home_text "UpdateService.isUpdateUiBusy"
require_home_text "_updateCheckTimer?.cancel()"

python3 - "$SERVICE" "$PUBLIC_ROUTES" "$CORE_LIVENESS_MONITOR" <<'PY'
import ipaddress
import re
import sys

source = open(sys.argv[1], encoding="utf-8").read()
route_source = open(sys.argv[2], encoding="utf-8").read()
liveness_source = open(sys.argv[3], encoding="utf-8").read()
wait_start = source.index("private fun waitForPendingStart(): Boolean")
wait_end = source.index("private fun stopBridgeWithTimeout()", wait_start)
if "BRIDGE_START_TIMEOUT_MS" in source[wait_start:wait_end]:
    raise SystemExit("Android cancellation still waits for the full bridge start timeout")
monitor_start = source.index("private fun monitorCoreRunning(")
monitor_end = source.index("private fun isBridgeRunningWithTimeout", monitor_start)
monitor = source[monitor_start:monitor_end]
if "CoreLivenessMonitor.waitForUnexpectedExit" not in monitor:
    raise SystemExit("Android VPN service does not delegate core liveness monitoring")
if "startToken != currentGeneration()" not in liveness_source:
    raise SystemExit("Android core monitor is not scoped to its start generation")
routes = [
    ipaddress.ip_network(f"{address}/{prefix}")
    for address, prefix in re.findall(
        r'Ipv4Route\("([0-9.]+)",\s*([0-9]+)\)', route_source
    )
]
if len(routes) != len(set(routes)):
    raise SystemExit("Android route table contains duplicate entries")

def routed(address: str) -> bool:
    ip = ipaddress.ip_address(address)
    return any(ip in route for route in routes)

for address in ("1.1.1.1", "2.2.2.2", "8.8.8.8", "11.0.0.1", "102.1.2.3", "103.1.2.3", "170.1.2.3", "223.255.255.254"):
    if not routed(address):
        raise SystemExit(f"Android public route coverage is missing {address}")

for address in ("10.1.2.3", "100.64.0.1", "172.16.0.1", "192.168.1.1"):
    if routed(address):
        raise SystemExit(f"Android local route exclusion is missing {address}")
PY

python3 - "$MAIN_ACTIVITY" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source.index("    override fun configureFlutterEngine(")
end = source.index("\n    private fun ", start)
line_count = len(source[start:end].splitlines())
if line_count > 30:
    raise SystemExit(
        f"MainActivity.configureFlutterEngine grew to {line_count} lines; "
        "keep channel actions in focused handlers"
    )
PY

python3 - "$SERVICE" "$NOTIFICATION_SUPPORT" <<'PY'
import sys
from pathlib import Path

service = Path(sys.argv[1])
support = Path(sys.argv[2])
line_count = len(service.read_text(encoding="utf-8").splitlines())
if line_count > 900:
    raise SystemExit(f"{service}: VPN service grew to {line_count} lines")
if "fun formatBytes(bytes: Long)" not in support.read_text(encoding="utf-8"):
    raise SystemExit(f"{support}: missing notification byte formatter")
PY

echo "Android native bridge guard check passed."
