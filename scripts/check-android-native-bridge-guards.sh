#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/SsrvpnVpnService.kt"
MAIN_ACTIVITY="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/MainActivity.kt"
DISCONNECT_RECOVERY_ACTIVITY="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/DisconnectRecoveryActivity.kt"
DISCONNECT_RECOVERY_COORDINATOR="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/DisconnectRecoveryCoordinator.kt"
TILE_SERVICE="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/VpnTileService.kt"
AUTO_CONNECT_REGISTRY="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/AutoConnectRequestRegistry.kt"
DETACHED_TUN_FD_OWNER="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/DetachedTunFdOwner.kt"
BUILD_GRADLE="$ROOT/SSRVPN_Android/android/app/build.gradle.kts"
MANIFEST="$ROOT/SSRVPN_Android/android/app/src/main/AndroidManifest.xml"
DISCONNECT_RECOVERY_LAYOUT="$ROOT/SSRVPN_Android/android/app/src/main/res/layout/activity_disconnect_recovery.xml"
DISCONNECT_RECOVERY_BACKGROUND="$ROOT/SSRVPN_Android/android/app/src/main/res/drawable/disconnect_recovery_background.xml"
ANDROID_STYLES="$ROOT/SSRVPN_Android/android/app/src/main/res/values/styles.xml"
ANDROID_NIGHT_STYLES="$ROOT/SSRVPN_Android/android/app/src/main/res/values-night/styles.xml"
ANDROID_STRINGS="$ROOT/SSRVPN_Android/android/app/src/main/res/values/strings.xml"
HOME_DART="$ROOT/SSRVPN_Android/lib/screens/home_screen.dart"
HOME_PARTS=(
  "$ROOT/SSRVPN_Android/lib/screens/home_connection_actions_part.dart"
  "$ROOT/SSRVPN_Android/lib/screens/home_lifecycle_actions_part.dart"
  "$ROOT/SSRVPN_Android/lib/screens/home_node_actions_part.dart"
  "$ROOT/SSRVPN_Android/lib/screens/home_public_ip_part.dart"
)
PUBLIC_ROUTES="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/PublicIpv4Routes.kt"
VPN_ROUTE_INSTALLER="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/VpnRouteInstaller.kt"
VPN_APP_EXCLUSION_INSTALLER="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/VpnAppExclusionInstaller.kt"
VPN_DATA_PLANE_PROBE="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/VpnDataPlaneProbe.kt"
VPN_PROTECT_MONITOR="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/VpnProtectMonitor.kt"
NOTIFICATION_SUPPORT="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/VpnNotificationSupport.kt"
NOTIFICATION_GATE="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/NotificationGenerationGate.kt"
CORE_LIVENESS_MONITOR="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/CoreLivenessMonitor.kt"
CORE_PORT_RELEASE_VERIFIER="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/CorePortReleaseVerifier.kt"
CORE_STOP_DECISION="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/CoreStopDecision.kt"
CORE_ELF_VERIFIER="$ROOT/scripts/verify_android_core_elf.py"
CORE_SOURCE_TEST="$ROOT/scripts/test_android_core_source.py"
NATIVE_SNAPSHOT_STORE="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/NativeConnectionSnapshotStore.kt"
NATIVE_CONNECTION_SESSION="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/NativeConnectionSession.kt"
NATIVE_SESSION_COORDINATOR="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/NativeVpnSessionCoordinator.kt"
NATIVE_RUNTIME_DIAGNOSTICS="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/NativeRuntimeDiagnostics.kt"
NATIVE_SESSION_COMMITTER="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/NativeSessionCommitter.kt"
NATIVE_START_PAYLOAD_REGISTRY="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/NativeStartPayloadRegistry.kt"
VPN_RESTART_STORE="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/VpnServiceRestartStore.kt"
TRAFFIC_TRACKER="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/VpnTrafficTracker.kt"
START_RESULT_REGISTRY="$ROOT/SSRVPN_Android/android/app/src/main/kotlin/com/ssrvpn/android/VpnStartResultRegistry.kt"
STARTUP_ORCHESTRATOR="$ROOT/SSRVPN_Android/lib/startup/startup_orchestrator.dart"
CLASH_DART="$ROOT/SSRVPN_Android/lib/services/clash_service.dart"
CLASH_NATIVE_BRIDGE="$ROOT/SSRVPN_Android/lib/services/clash_service_native_bridge.dart"

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

require_file_text() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$file"; then
    echo "Android native file guard failed in $file: missing '$needle'" >&2
    exit 1
  fi
}

require_file_text "$VPN_PROTECT_MONITOR" "ParcelFileDescriptor.fromFd("
python3 "$CORE_ELF_VERIFIER" \
  "$ROOT/SSRVPN_Android/android/app/src/main/jniLibs/arm64-v8a/libgojni.so"
python3 "$CORE_SOURCE_TEST"
if grep -Fq "ParcelFileDescriptor.adoptFd(" "$VPN_PROTECT_MONITOR"; then
  echo "Android protect monitor must duplicate the native-owned pipe descriptor" >&2
  exit 1
fi

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

if grep -Fq "syncSettings" "$STARTUP_ORCHESTRATOR"; then
  echo "Android startup must not overwrite the last committed native snapshot" >&2
  exit 1
fi

require_text "BRIDGE_START_TIMEOUT_MS"
require_text "PENDING_START_CANCEL_GRACE_MS = 1_000L"
require_text "serviceStartInProgress.compareAndSet(false, true)"
require_text "processTerminationPending.get()"
require_text "processTerminationPending.set(true)"
require_text "startGeneration.invalidate {"
grep -Fq "NativeConnectionSession.beginStarting(claimId)" "$NATIVE_SESSION_COORDINATOR" || {
  echo "Android native start lease is not consumed by the session coordinator" >&2
  exit 1
}
require_text "startGeneration.runIfCurrent(startToken)"
require_text "ensureStartCurrent(startToken)"
grep -Fq "fun connectionState(): Map<String, Any?>" "$NATIVE_SESSION_COORDINATOR" || {
  echo "Android native session coordinator lost the atomic state snapshot" >&2
  exit 1
}
require_text "NativeConnectionSession.publishRunning(configPath)"
require_text "NativeVpnSessionCoordinator.reserveRecovery(request.configPath)"
require_text "NativeConnectionSession.clearRunning()"
require_text "if (stopDecision.clearRunningSession)"
require_text "NativeConnectionSession.clearRecovery()"
require_text "CoreRecoveryPolicy.nextAttempt(request.attempt)"
require_text "stopForRecovery"
require_text "showCoreRecoveryFailedNotification"
require_text "EXTRA_RECOVERY_ATTEMPT"
require_text "EXTRA_RECOVERY_TOKEN"
require_text "CoreRecoveryPolicy.shouldAcceptRestart("
require_text "VpnServiceRestartStore.shouldAcceptStickyRestart(this)"
require_text "VpnServiceRestartStore.recordExplicitStart(this)"
require_text "VpnServiceRestartStore.recordManualStop(this)"
require_file_text "$VPN_RESTART_STORE" "internal object StickyVpnRestartPolicy"
require_file_text "$VPN_RESTART_STORE" "editor.commit()"

python3 - "$SERVICE" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
start = source[source.index("override fun onStartCommand"):]
sticky_guard = start.index("VpnServiceRestartStore.shouldAcceptStickyRestart(this)")
snapshot = start.index("NativeConnectionSnapshotStore.read(this)")
if sticky_guard >= snapshot:
    raise SystemExit("Android sticky restart intent is checked after snapshot replay")
on_destroy = source[source.index("override fun onDestroy()") :]
if "stopAll(recordManualStop = false)" not in on_destroy:
    raise SystemExit("Android service destruction is incorrectly persisted as a user disconnect")
stop_all = source[source.index("fun stopAll("):source.index("private fun stopInternal(")]
if "recordManualStop: Boolean = false" not in stop_all:
    raise SystemExit("Android internal VPN cleanup defaults to a persisted user disconnect")
for needle in (
    "instance?.stopAll(recordManualStop = true)",
    "stopAll(recordManualStop = true)",
):
    if needle not in source:
        raise SystemExit(f"Android explicit disconnect lost persisted intent: {needle}")
PY

python3 - "$SERVICE" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
selection = source.index("applyProxySelection(apiPort, apiSecret, selectedNodeName)")
publish = source.index("isRunning = true", selection)
if "startGeneration.runIfCurrent(startToken)" not in source[selection:publish]:
    raise SystemExit("Android VPN publishes connected state outside the atomic generation gate")
PY

python3 - "${HOME_PARTS[0]}" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
remember = source.index("await _rememberSelectedNode(")
connected_publish = source.index("_isConnected = true", remember)
window = source[remember:connected_publish]
if window.count("isConnectionIntentCurrent(") < 2:
    raise SystemExit(
        "Android home must revalidate connection intent after persisting the selected node"
    )
if "if (!clashService.isRunning)" not in window:
    raise SystemExit(
        "Android home must confirm the core is still running before publishing connected UI"
    )
core_down = window[window.index("if (!clashService.isRunning)") :]
if "_isConnecting = false" not in core_down or "连接已中断" not in core_down:
    raise SystemExit(
        "Android home must clear the spinner when the core stops during node persistence"
    )
PY
python3 - "${HOME_PARTS[1]}" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
load = source[source.index("Future<void> _loadInitialData() async") :]
register = load.index("clashService.onStatusChanged = _onClashStatusChanged")
runtime_query = load.index("await clashService.currentSelectedProxyName()")
node_capture = load.index("HomeNodeController.runnableNodesFrom(subService.allNodes)")
if not (register < runtime_query < node_capture):
    raise SystemExit(
        "Android home must register status recovery before awaits and capture nodes afterwards"
    )
for needle in (
    "final statusEpoch = _connectionStatusEpoch",
    "statusEpoch == _connectionStatusEpoch",
    "final statusEpoch = ++_connectionStatusEpoch",
):
    if needle not in load:
        raise SystemExit(f"Android home status reconciliation is missing: {needle}")
PY
python3 - "${HOME_PARTS[2]}" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
handle = source[source.index("Future<void> _handleSelectNode(") :]
perform = handle[handle.index("Future<void> _performSelectNode(") :]
for needle in (
    "final statusEpoch = _connectionStatusEpoch",
    "_performSelectNode(node, clashService, generation, statusEpoch)",
    "statusEpoch == _connectionStatusEpoch",
):
    if needle not in handle:
        raise SystemExit(
            f"Android node selection recovery guard is missing: {needle}"
        )
if "statusEpoch == _connectionStatusEpoch" not in perform:
    raise SystemExit("Android node selection is not scoped to one native status epoch")
persist = perform.index("await _writePreferredNodeConfigForTile(")
remember = perform.index("await _rememberSelectedNode(")
if persist >= remember:
    raise SystemExit("Android node preference is published before the session-bound snapshot")
if "await clashService.currentSelectedProxyName()" not in perform:
    raise SystemExit("Android node selection lacks a runtime fallback after persistence failure")
PY
require_text "waitForPendingStart()"
require_text "VPN is already running; reusing the active session"
require_text "createStartIntent"
if grep -Eq 'EXTRA_(CONFIG_DIR|CONFIG_PATH|API_PORT|API_SECRET|NODE_NAME)' "$SERVICE"; then
  echo "Android service intents must not carry runtime paths or credentials" >&2
  exit 1
fi
require_text "NativeConnectionSnapshotStore.read(this)"
require_text "NativeStartPayloadRegistry.consume(startPayloadId)"
grep -Fq "NativeStartPayloadRegistry.peek(" "$NATIVE_SESSION_COORDINATOR" || {
  echo "Android activity start lease cannot resolve its in-memory payload" >&2
  exit 1
}
grep -Fq "ConcurrentHashMap<String, NativeConnectionSnapshot>" \
  "$NATIVE_START_PAYLOAD_REGISTRY" || {
  echo "Android foreground start payloads lost one-time in-memory ownership" >&2
  exit 1
}
grep -Fq "NativeConnectionPathPolicy.requireTrusted" "$NATIVE_SNAPSHOT_STORE" || {
  echo "Android native snapshots are not confined to the private app directory" >&2
  exit 1
}
grep -Fq "ExternalUrlPolicy.normalizedHttpUrl" "$MAIN_ACTIVITY" || {
  echo "Android external URL launch is missing its HTTP(S) policy" >&2
  exit 1
}
for needle in "fun reset()" "fun resetSample()" \
  "fun update(bytesPerSecond: (Long, Long) -> Long)" "fun snapshot()"; do
  python3 - "$TRAFFIC_TRACKER" "$needle" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
needle = sys.argv[2]
position = source.index(needle)
prefix = source[max(0, position - 40):position]
if "@Synchronized" not in prefix:
    raise SystemExit(f"Android traffic state mutation is not atomic: {needle}")
PY
done
grep -Fq "synchronized(this)" "$NATIVE_CONNECTION_SESSION" || {
  echo "Android native connection compound state is not synchronized" >&2
  exit 1
}
require_text "waitForProtectMonitor("
require_text "vpnFd = null"
require_text "BRIDGE_STOP_TIMEOUT_MS"
require_text "BRIDGE_IS_RUNNING_TIMEOUT_MS"
require_text "startBridgeWithTimeout"
require_text "stopBridgeWithTimeout"
require_text "isBridgeRunningWithTimeout"
grep -Fq "CorePortReleaseVerifier::waitUntilAllReleased" "$CORE_STOP_DECISION" || {
  echo "Android stop decision no longer verifies data plane port release" >&2
  exit 1
}
grep -Fq "DEFAULT_RELEASE_ATTEMPTS = 51" "$CORE_PORT_RELEASE_VERIFIER" || {
  echo "Android core port release grace period regressed below five seconds" >&2
  exit 1
}
require_text "CoreStopDecision.afterBridgeCheck("
require_text "stopDecision.terminationMessage(currentDataPorts)"
require_text "return bridgeFdTerminationRequired.get() || stopDecision.terminateProcess"
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

python3 - "$SERVICE" "$DETACHED_TUN_FD_OWNER" "$CORE_STOP_DECISION" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
owner = Path(sys.argv[2]).read_text(encoding="utf-8")
stop_policy = Path(sys.argv[3]).read_text(encoding="utf-8")
start_core = source[
    source.index("private fun startCoreWithVpn("):
    source.index("private fun startBridgeWithTimeout(")
]
establish = start_core.index("vpnFd = builder.establish()")
protect_init = start_core.index("bridge.Bridge.initProtect()")
protect_monitor = start_core.index("VpnProtectMonitor.start(")
detach = start_core.index("DetachedTunFdOwner.detach(bridgeDescriptor)")
if not establish < protect_init < protect_monitor < detach:
    raise SystemExit(
        "Android protect pipe must start only after VPN establish and before fd detach"
    )
bridge_start = source.index("private fun startBridgeWithTimeout(")
bridge_stop = source.index("private fun monitorCoreRunning(", bridge_start)
start = source[bridge_start:bridge_stop]
if "tunFdOwner.startWithBridge(" not in start:
    raise SystemExit("Android TUN fd ownership transaction escaped its owner")
if "bridgeFdTerminationRequired.set(true)" not in start:
    raise SystemExit("Android ambiguous Bridge.start ownership does not force process cleanup")
for throwable_guard in (
    "var error: Throwable? = null",
    "catch (e: Throwable)",
    "throw it.asBridgeStartException()",
):
    if throwable_guard not in start:
        raise SystemExit(f"Android Bridge.start Throwable can escape as success: {throwable_guard}")
if "return bridgeFdTerminationRequired.get() || stopDecision.terminateProcess" not in source:
    raise SystemExit("Android stop can ignore ambiguous Bridge.start fd ownership")
stop_internal = source[
    source.index("private fun stopInternal("):source.index("private fun stopAllOnWorker()")
]
runner_call = stop_internal.index("StopOperationRunner.run(")
initial = stop_internal.index("bridgeFdTerminationRequired.get()", runner_call)
cleanup = stop_internal.index("::stopAllOnWorker", initial)
handoff = stop_internal.index("processTerminationPending.set(true)", cleanup)
complete = stop_internal.index("stopOperation::complete", handoff)
schedule = stop_internal.index("notificationHandler.postDelayed(", complete)
failure_log = stop_internal.index("Stop cleanup failed; process termination scheduled", schedule)
if not runner_call < initial < cleanup < handoff < complete < schedule < failure_log:
    raise SystemExit("Android cleanup exceptions can bypass ambiguous fd process termination")

runner = stop_policy[stop_policy.index("internal object StopOperationRunner"):]
runner_body = runner[runner.index("var terminationRequired"):]
cleanup_call = runner_body.index("val cleanupRequiresTermination = cleanup()")
merge = runner_body.index(
    "terminationRequired = terminationRequired || cleanupRequiresTermination",
    cleanup_call
)
catch = runner_body.index("catch (error: Throwable)", merge)
force = runner_body.index("terminationRequired = true", catch)
record_failure = runner_body.index("cleanupFailure = error", force)
handoff_callback = runner_body.index(
    "if (terminationRequired) onTerminationRequired()", record_failure
)
complete_callback = runner_body.index("complete(!terminationRequired)", handoff_callback)
schedule_callback = runner_body.index(
    "if (terminationRequired) scheduleTermination()", complete_callback
)
return_failure = runner_body.index("return cleanupFailure", schedule_callback)
if not (
    cleanup_call < merge < catch < force < record_failure < handoff_callback
    < complete_callback < schedule_callback < return_failure
):
    raise SystemExit("Android stop operation runner is not fail-closed")

transaction = owner[owner.index("fun startWithBridge("):owner.index("private fun beginBridgeStart(")]
prepare = transaction.index("prepareBridge()")
begin = transaction.index("beginBridgeStart()")
native_call = transaction.index("startBridge(descriptor)")
success = transaction.index("result.isEmpty()")
commit = transaction.index("commitBridgeOwnership()")
known_failure = transaction.index("isProvenPreAdoptionFailure(result)")
failure_close = transaction.index("closeAfterKnownPreAdoptionFailure()")
ambiguous = transaction.index("markOwnershipAmbiguous()", failure_close)
termination = transaction.index("requireProcessTermination()", ambiguous)
if not prepare < begin < native_call < success < commit < known_failure < failure_close:
    raise SystemExit(
        "Android TUN fd ownership is not committed only after Bridge.start succeeds"
    )
if not failure_close < ambiguous < termination:
    raise SystemExit(
        "Android unknown Bridge.start errors can close a possibly reused raw fd"
    )
for throwable_guard in (
    "catch (error: Throwable)",
    "throw error.asBridgeStartException()",
):
    if throwable_guard not in transaction:
        raise SystemExit(f"Android Bridge.start Throwable ownership is unguarded: {throwable_guard}")
for exact_guard in (
    'result == "already running"',
    'result.startsWith("read config: ")',
    'result.startsWith("parse config: ")',
):
    if exact_guard not in owner:
        raise SystemExit(f"Android proven pre-adoption error guard is missing: {exact_guard}")

start = source.index("private fun stopBridgeWithTimeout(): Boolean")
stop = source[start:]
if "isBridgeRunningWithTimeout()" not in stop:
    raise SystemExit(
        "Android stop completion is not verified against Bridge.isRunning"
    )
if stop.index("isBridgeRunningWithTimeout()") < stop.index("bridge.Bridge.stop()"):
    raise SystemExit(
        "Android verifies Bridge state before asking the core to stop"
    )

running_start = source.index("private fun isBridgeRunningWithTimeout(): Boolean?")
running_end = source.index("\n    private fun ", running_start + 1)
running_check = source[running_start:running_end]
if "return null" not in running_check:
    raise SystemExit(
        "Android Bridge probe no longer preserves an explicit unknown state"
    )
if "isBridgeRunningWithTimeout() == false" not in stop:
    raise SystemExit("Android stop treats an unknown Bridge probe as stopped")
if "{ isBridgeRunningWithTimeout() != false }" not in source:
    raise SystemExit("Android liveness monitor no longer fails open on probe errors")
PY

require_activity_text '"syncSettings"'
require_activity_text '"getConnectionState"'
require_activity_text '"getNativeDiagnostics"'
require_activity_text '"expectedSessionGeneration"'
require_activity_text '"Active native VPN session requires a generation"'
require_activity_text '"getConnectionSnapshotGeneration"'
require_activity_text '"clearConnectionSnapshot"'
require_activity_text "private fun handleNativeMethodCall("
require_activity_text "NativeVpnSessionCoordinator.commitIdleSnapshot(this, snapshot)"
require_activity_text "NativeVpnSessionCoordinator.clearIdleSnapshot("
require_activity_text '"flutter.proxyPort"'
require_activity_text '"flutter.socksPort"'
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
if grep -Fq '"AUTO_CONNECT"' "$MAIN_ACTIVITY" "$TILE_SERVICE"; then
  echo "Android exported activity must not trust the legacy AUTO_CONNECT boolean" >&2
  exit 1
fi
for needle in \
  "AutoConnectRequestRegistry.consume(this, requestId)" \
  "removeExtra(AutoConnectRequestRegistry.EXTRA_REQUEST_ID)"; do
  require_activity_text "$needle"
done
require_tile_text "AutoConnectRequestRegistry.issue(this)"
for needle in \
  "UUID.randomUUID().toString()" \
  "MAX_PENDING_REQUESTS = 16" \
  "REQUEST_TTL_MS = 60_000L" \
  "Context.MODE_PRIVATE" \
  "editor.commit()" \
  "return requestId.takeIf { store.replace(pending) }" \
  "return store.replace(pending)"; do
  grep -Fq "$needle" "$AUTO_CONNECT_REGISTRY" || {
    echo "Android auto-connect capability guard failed: missing '$needle'" >&2
    exit 1
  }
done
if grep -Fq "private val pending" "$AUTO_CONNECT_REGISTRY"; then
  echo "Android auto-connect capabilities must survive main-process recreation" >&2
  exit 1
fi
python3 - "$AUTO_CONNECT_REGISTRY" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
consume = source[source.index("internal fun consume("):source.index("private fun activeEntries(")]
remove = consume.index("pending.remove(requestId)")
persist = consume.index("return store.replace(pending)", remove)
if remove >= persist:
    raise SystemExit("Android auto-connect capability is authorized before one-shot persistence")
for required in (
    "isCanonicalUuid(requestId)",
    "issuedAt <= nowMillis",
    "age >= 0L",
    "age < REQUEST_TTL_MS",
):
    if required not in source:
        raise SystemExit(f"Android auto-connect capability validation is missing: {required}")
PY
grep -Fq "callback == null || !await consumePendingAutoConnect()" \
  "$CLASH_NATIVE_BRIDGE" || {
  echo "Android auto-connect wake-up no longer consumes one pending request" >&2
  exit 1
}

python3 - "$SERVICE" "$NATIVE_RUNTIME_DIAGNOSTICS" <<'PY'
import sys
from pathlib import Path

service = Path(sys.argv[1]).read_text(encoding="utf-8")
runtime = Path(sys.argv[2]).read_text(encoding="utf-8")
for forbidden in (
    "tunEstablished = serviceRunning,",
    "bridgeReady = serviceRunning,",
):
    if forbidden in runtime:
        raise SystemExit(f"Android native diagnostics inferred health: {forbidden}")
for required in (
    "beginTunLease",
    "claimTunDescriptor",
    "TunOwnershipClaim",
    "baselineInterfaceNames",
    "releaseTunDescriptorIfClosed",
    "tunInterfaceNames",
    'Os.readlink("/proc/self/fd/$descriptor")',
    "resolveOwnedTunInterfaces(claim, currentTunInterfaces)",
    "bridgeReady = bridgeReady",
):
    if required not in runtime:
        raise SystemExit(f"Android native diagnostics lost real probe: {required}")
for required in (
    "runtimeDiagnostics.beginTunLease()",
    "runtimeDiagnostics.claimTunDescriptor(tunFd)",
    "runtimeDiagnostics::releaseTunDescriptorIfClosed",
):
    if required not in service:
        raise SystemExit(f"Android VPN service lost diagnostic ownership hook: {required}")
start_core = service[
    service.index("private fun startCoreWithVpn("):
    service.index("private fun ensureStartCurrent(")
]
detach = start_core.index("DetachedTunFdOwner.detach(bridgeDescriptor)")
claim = start_core.index("runtimeDiagnostics.claimTunDescriptor(tunFd)")
bridge_start = start_core.index("startBridgeWithTimeout(configDir, configPath, tunFdOwner)")
if not detach < claim < bridge_start:
    raise SystemExit(
        "Android TUN ownership must be claimed before Bridge start can be cancelled"
    )
PY
grep -Fq "ConcurrentHashMap<String" "$START_RESULT_REGISTRY" || {
  echo "Android start callback registry lost its concurrent ownership map" >&2
  exit 1
}
require_tile_text "VpnStartResultRegistry.clear(requestId)"
require_activity_text "VpnStartResultRegistry.register(callback)"
require_tile_text "SsrvpnVpnService.isCoreOperationBusy()"
require_tile_text "SsrvpnVpnService.cancelPendingStart()"
require_tile_text "service.stopAll(recordManualStop = true) {"
require_tile_text "isConnected = SsrvpnVpnService.isRunning"
require_tile_text "SsrvpnVpnService.createStartIntent"
require_tile_text "NativeVpnSessionCoordinator.claimSnapshotForStart(this)"
require_tile_text "NativeVpnSessionCoordinator.releasePendingStart(claim.id)"
require_activity_text "vpnPermissionRequestPending"
require_activity_text "startVpnServiceWithTimeout"
require_activity_text "pendingVpnServiceIntent"
require_activity_text "SsrvpnVpnService.createStartIntent"
require_activity_text "AtomicBoolean(false)"
require_activity_text "Manifest.permission.POST_NOTIFICATIONS"
require_activity_text "NOTIFICATION_PERMISSION_REQUESTED"
require_activity_text "requestNotificationPermissionOnce"
require_activity_text "Build.VERSION_CODES.TIRAMISU"

python3 - "$TILE_SERVICE" "$MAIN_ACTIVITY" "$NATIVE_CONNECTION_SESSION" <<'PY'
import sys
from pathlib import Path

tile = Path(sys.argv[1]).read_text(encoding="utf-8")
activity = Path(sys.argv[2]).read_text(encoding="utf-8")
session = Path(sys.argv[3]).read_text(encoding="utf-8")
claim = tile.index("NativeVpnSessionCoordinator.claimSnapshotForStart(this)")
intent = tile.index("SsrvpnVpnService.createStartIntent(", claim)
launch = tile.index("startForegroundService(intent)", intent)
if not claim < intent < launch:
    raise SystemExit("Android tile start lease is not acquired before service launch")
main_claim = activity.index("NativeVpnSessionCoordinator.claimPendingStart(")
main_launch = activity.index("startVpnService(serviceIntent)", main_claim)
if main_claim >= main_launch:
    raise SystemExit("Android activity start lease is not acquired before service launch")
idle_clear = session[session.index("fun clearIdleSnapshot(") :]
for needle in ("gate.withCurrent", "!isTransitioning()", "clearIfGeneration"):
    if needle not in idle_clear:
        raise SystemExit(f"Android idle snapshot clear lost lease guard: {needle}")
PY

require_text "Bridge.isRunning already in progress; deferring verdict"
require_text "Bridge.isRunning timed out after"
require_text "treating stop as unverified"
require_text "Core shutdown incomplete; terminating process to release the detached TUN fd"
require_text "android.os.Process.killProcess(android.os.Process.myPid())"
require_text "DisconnectRecoveryCoordinator.handoffIfNeeded(this, preserveForegroundUi)"
require_text "if (!processTerminationPending.get()) stopAll(recordManualStop = false)"
require_activity_text "VpnServiceRestartStore.recordManualStop(this)"
require_activity_text "recordManualStop = true"
require_tile_text "VpnServiceRestartStore.recordManualStop(this)"
require_tile_text "service.stopAll(recordManualStop = true)"
require_activity_text "VPN start timeout cleanup failed"
require_activity_text "error.javaClass.simpleName"
# These manifest placeholders must be matched literally, not expanded by Bash.
# shellcheck disable=SC2016
for needle in \
  'android:name=".DisconnectRecoveryActivity"' \
  'android:exported="false"' \
  'android:process=":disconnect_recovery"' \
  'android:taskAffinity="${applicationId}.disconnect_recovery"' \
  'android:theme="@style/DisconnectRecoveryTheme"'; do
  require_manifest_text "$needle"
done
for needle in \
  "foregroundUiRequested && processTerminationRequired" \
  "DisconnectRecoveryActivity.handoff(context)"; do
  grep -Fq "$needle" "$DISCONNECT_RECOVERY_COORDINATOR" || {
    echo "Android disconnect recovery policy guard failed: missing '$needle'" >&2
    exit 1
  }
done
for needle in \
  "RELAUNCH_DELAY_MS = 1_500L" \
  "Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS" \
  "Intent.FLAG_ACTIVITY_NO_ANIMATION"; do
  grep -Fq "$needle" "$DISCONNECT_RECOVERY_ACTIVITY" || {
    echo "Android disconnect recovery activity guard failed: missing '$needle'" >&2
    exit 1
  }
done
python3 - "$DISCONNECT_RECOVERY_ACTIVITY" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
content = source.index("setContentView(R.layout.activity_disconnect_recovery)")
relaunch = source.index("handler.postDelayed(relaunch, RELAUNCH_DELAY_MS)")
if content >= relaunch:
    raise SystemExit(
        "Android disconnect recovery activity does not render before relaunch scheduling"
    )
PY
for needle in \
  '@mipmap/ic_launcher' \
  '@string/disconnect_recovery_status' \
  '<ProgressBar'; do
  grep -Fq "$needle" "$DISCONNECT_RECOVERY_LAYOUT" || {
    echo "Android disconnect recovery layout guard failed: missing '$needle'" >&2
    exit 1
  }
done
for styles in "$ANDROID_STYLES" "$ANDROID_NIGHT_STYLES"; do
  for needle in \
    'style name="DisconnectRecoveryTheme"' \
    '<item name="android:windowBackground">@drawable/disconnect_recovery_background</item>'; do
    grep -Fq "$needle" "$styles" || {
      echo "Android disconnect recovery theme guard failed in $styles: missing '$needle'" >&2
      exit 1
    }
  done
done
grep -Fq '@color/disconnect_recovery_background' "$DISCONNECT_RECOVERY_BACKGROUND" || {
  echo "Android disconnect recovery window lost its branded background" >&2
  exit 1
}
grep -Fq '<string name="disconnect_recovery_status">' "$ANDROID_STRINGS" || {
  echo "Android disconnect recovery status string is missing" >&2
  exit 1
}
require_text "VpnRouteInstaller.configure(builder)"
require_route_text "PublicIpv4Routes.routes"
require_route_text "configure(builder::addAddress, builder::addRoute, builder::addDnsServer)"
require_route_text 'private const val clientAddress = "172.19.0.1"'
require_route_text 'private const val clientPrefixLength = 30'
require_route_text 'private const val dnsAddress = "172.19.0.2"'
require_route_text 'addDnsServer(dnsAddress)'
require_route_text 'addRoute(dnsAddress, 32)'
require_route_text "VpnIpv6Config.address"
require_route_text "addRoute(route.address, route.prefixLength)"
require_route_text "VpnIpv6Config.defaultRoute"
require_text "builder.setBlocking(false)"
require_text "VpnAppExclusionInstaller.install(builder)"
require_text "VpnDataPlaneProbe.isStartupHealthy("
require_text '"VPN 数据通道不可用，请切换节点或重试"'
require_file_text "$VPN_DATA_PLANE_PROBE" '"https://www.gstatic.com/generate_204"'
require_file_text "$VPN_DATA_PLANE_PROBE" '"https://www.youtube.com/generate_204"'
require_file_text "$VPN_DATA_PLANE_PROBE" '"https://cp.cloudflare.com/generate_204"'
require_file_text "$VPN_DATA_PLANE_PROBE" "HttpURLConnection.HTTP_NO_CONTENT"
require_file_text "$VPN_APP_EXCLUSION_INSTALLER" "fun install(builder: VpnService.Builder)"
require_file_text "$VPN_APP_EXCLUSION_INSTALLER" "DomesticAppBypassPolicy.applyInstalled"
require_file_text "$VPN_APP_EXCLUSION_INSTALLER" "adbPackages.forEach"
if grep -Fq "vpnPackageName" "$VPN_APP_EXCLUSION_INSTALLER" ||
  grep -Fq "VpnAppExclusionInstaller.install(builder, packageName)" "$SERVICE"; then
  echo "Android VPN app exclusion guard failed: SSRVPN must stay inside its own TUN" >&2
  exit 1
fi
require_text "VpnNotificationSupport.createChannel(this, CHANNEL_ID)"
require_file_text "$NOTIFICATION_SUPPORT" "PendingIntent.getService("
require_file_text "$NOTIFICATION_SUPPORT" "R.drawable.ic_disconnect"
require_text "intent?.action == ACTION_DISCONNECT"
require_text "NativeConnectionSnapshotStore.read(this)"
require_text "notificationUpdatePolicy.publishIfChanged(it)"
if ! grep -Fq "Looper.myLooper() != handler.looper" "$NOTIFICATION_GATE"; then
  echo "Android notification generation guard lost its main-thread handoff" >&2
  exit 1
fi
require_text "notificationGeneration.publishLatest("
require_text "CoreRecoveryPolicy.shouldPublishRecovery("
require_activity_text "NATIVE_SNAPSHOT_UPDATE_FAILED"

for needle in \
  "await _queryNativeConnectionState()" \
  "_ensureNativeSessionForMutation" \
  "final nativeStateEpoch = ++_nativeStateEpoch" \
  "nativeStateEpoch == _nativeStateEpoch"; do
  grep -Fq "$needle" "$CLASH_NATIVE_BRIDGE" || {
    echo "Android active config identity guard failed: missing '$needle'" >&2
    exit 1
  }
done
for needle in \
  "'expectedSessionGeneration': expectedSessionGeneration" \
  "postCommitState?.sessionGeneration" \
  "原生 VPN 会话已变更或正在恢复"; do
  grep -Fq "$needle" "$CLASH_DART" || {
    echo "Android session-bound snapshot guard failed: missing '$needle'" >&2
    exit 1
  }
done
for needle in \
  "recoveryConfigPath" \
  "startingConfigPath" \
  "pendingStartClaimId" \
  "claimSnapshotForStart" \
  "beginStarting" \
  "commitIdleSnapshot" \
  "snapshotConsistently" \
  "sessionGeneration.takeIf { running }"; do
  grep -Fq "$needle" "$NATIVE_CONNECTION_SESSION" || {
    echo "Android native recovery reservation guard failed: missing '$needle'" >&2
    exit 1
  }
done
for needle in \
  "capturedState" \
  "result.success(capturedState)"; do
  grep -Fq "$needle" "$MAIN_ACTIVITY" || {
    echo "Android immutable start result guard failed: missing '$needle'" >&2
    exit 1
  }
done
for needle in \
  'rawRunning is! bool || rawTransitioning is! bool' \
  'running != (sessionGeneration != null)' \
  '无法确认原生 VPN 启动状态'; do
  grep -Fq "$needle" "$CLASH_NATIVE_BRIDGE" "$CLASH_DART" || {
    echo "Android native state validation guard failed: missing '$needle'" >&2
    exit 1
  }
done
for needle in \
  '"PERMISSION_DENIED"' \
  'Unable to request VPN permission' \
  '无法打开 VPN 授权页面，请检查系统设置后重试'; do
  grep -Fq "$needle" "$MAIN_ACTIVITY" || {
    echo "Android VPN permission UX guard failed: missing '$needle'" >&2
    exit 1
  }
done
for needle in \
  "gate.runIfCurrent(expectedSessionGeneration)" \
  "NativeConnectionSnapshotStore.updateSelectedNode" \
  "NativeConnectionSnapshotStore.write"; do
  grep -Fq "$needle" "$NATIVE_SESSION_COMMITTER" || {
    echo "Android native session commit guard failed: missing '$needle'" >&2
    exit 1
  }
done

if grep -R -n -E 'flutter\.(apiSecret|configDir|configPath|apiPort|selectedNodeName)' \
  "$MAIN_ACTIVITY" "$SERVICE" "$TILE_SERVICE"; then
  echo "Android native snapshot guard failed: split Flutter preferences are still used" >&2
  exit 1
fi
for needle in \
  'AndroidKeyStore' \
  'AES/GCM/NoPadding' \
  'setRandomizedEncryptionRequired(true)' \
  'snapshot_generation' \
  'clearIfGeneration'; do
  grep -Fq "$needle" "$NATIVE_SNAPSHOT_STORE" || {
    echo "Android native credential guard failed: missing '$needle'" >&2
    exit 1
  }
done

python3 - "${HOME_PARTS[1]}" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
handler = source[source.index("void _handleClashStatusChanged()") :]
for required in (
    "shouldHandleAndroidHomeConnectionStatus(",
    "transitionAndroidHomeConnectionStatus(",
    "_isConnecting = transition.connecting",
    "_errorMessage = transition.errorMessage",
    "_selectedNode = transition.selectedNode",
):
    if required not in handler:
        raise SystemExit(
            f"Android recovery UI transition guard missing {required!r}"
        )
PY
grep -Fq "fun clearIfGeneration(" "$NATIVE_SNAPSHOT_STORE" || {
  echo "Android native snapshot guard failed: generation-bound clear is missing" >&2
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
# The Gradle manifest placeholder must remain literal here.
# shellcheck disable=SC2016
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
require_home_text "clashService.runConnectionTransition"
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
if line_count > 970:
    raise SystemExit(f"{service}: VPN service grew to {line_count} lines")
if "fun formatBytes(bytes: Long)" not in support.read_text(encoding="utf-8"):
    raise SystemExit(f"{support}: missing notification byte formatter")
PY

python3 - "$SERVICE" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
boundaries = (
    ("private fun startCoreWithVpn(", "private fun startBridgeWithTimeout("),
    ("private fun isBridgeRunningWithTimeout(", "internal fun runtimeDiagnosticsSnapshot("),
    ("private fun stopBridgeWithTimeout(", "override fun onDestroy()"),
)
for start_marker, end_marker in boundaries:
    start = source.index(start_marker)
    end = source.index(end_marker, start)
    if "catch (e: LinkageError)" not in source[start:end]:
        raise SystemExit(
            f"Android JNI crash boundary is missing LinkageError handling: {start_marker}"
        )
PY

python3 - "$SERVICE" "$MAIN_ACTIVITY" "$TILE_SERVICE" "$DISCONNECT_RECOVERY_ACTIVITY" <<'PY'
import sys
from pathlib import Path

service = Path(sys.argv[1]).read_text(encoding="utf-8")
activity = Path(sys.argv[2]).read_text(encoding="utf-8")
tile = Path(sys.argv[3]).read_text(encoding="utf-8")
recovery = Path(sys.argv[4]).read_text(encoding="utf-8")

service_boundaries = (
    ("override fun onStartCommand(", "private fun currentNotificationState()"),
    ("private fun notifyCurrentState(", "private fun startNotificationUpdates()"),
    ("private fun showCoreRecoveryFailedNotification()", "private fun isBridgeRunningWithTimeout()"),
)
for start_marker, end_marker in service_boundaries:
    start = service.index(start_marker)
    end = service.index(end_marker, start)
    if "AndroidRuntimeGuard.run(" not in service[start:end]:
        raise SystemExit(
            f"Android main-thread crash boundary is unguarded: {start_marker}"
        )

if activity.count("runOnUiThread {") != 1 or "runOnActiveUiThread(" not in activity:
    raise SystemExit("MainActivity async replies bypass the active-Activity crash boundary")
for source, needle in (
    (tile, "Unable to prepare VPN permission from tile"),
    (tile, "Unable to open SSRVPN from tile"),
    (tile, "Unable to update VPN tile"),
    (recovery, "Unable to relaunch SSRVPN after core reset"),
):
    if needle not in source:
        raise SystemExit(f"Android system callback crash boundary is missing: {needle}")
PY

echo "Android native bridge guard check passed."
