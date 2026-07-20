#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

runtime=(
  "SSRVPN_MacOS/lib/services/clash_service.dart"
  "SSRVPN_MacOS/lib/services/clash_service_lifecycle.dart"
  "SSRVPN_MacOS/lib/services/macos_tun_session.dart"
)
native="SSRVPN_MacOS/macos/Runner"
runner="SSRVPN_MacOS/assets/macos_tun_runner.sh"
desktop_home="packages/ssrvpn_shared/lib/desktop_ui/screens/desktop_home_screen_part.dart"
node_selection_controls="packages/ssrvpn_shared/lib/widgets/ssrvpn_node_selection_controls.dart"

for forbidden in \
  '_grantRootPrivilege' \
  '_coreHasRootPrivilege' \
  '/usr/sbin/chown' \
  'root:wheel' \
  'chmod u+s'; do
  if grep -R -n -F -- "$forbidden" "${runtime[@]}" "$native" "$runner" >/dev/null; then
    echo "macOS core privilege guard failed: found $forbidden" >&2
    exit 1
  fi
done

python3 - <<'PY'
from pathlib import Path
import re

path = Path("SSRVPN_MacOS/lib/services/clash_service.dart")
lifecycle_path = Path("SSRVPN_MacOS/lib/services/clash_service_lifecycle.dart")
main_source = path.read_text(encoding="utf-8")
lifecycle_source = lifecycle_path.read_text(encoding="utf-8")
source = f"{main_source}\n{lifecycle_source}"
if re.search(r'''['"][2467][0-7]{3}['"]|[ug]\+s''', source):
    raise SystemExit(f"{path}: found a privileged chmod mode")

for token in ("MacosTunSession", "_startTunCore", "tunSession.start()"):
    if token not in source:
        raise SystemExit(f"{path}: missing authorized TUN session boundary: {token}")
if "_tunUnavailableMessage" in source:
    raise SystemExit(f"{path}: obsolete TUN unavailable guard remains")

install = main_source.index("Future<void> _installCoreAsset")
generic_install = main_source.index("Future<void> _installAsset", install)
install_body = main_source[install:generic_install]
remove = install_body.index("_removeUntrustedPathEntry(destPath)")
decompress = install_body.index("Isolate.run")
if remove > decompress:
    raise SystemExit(f"{path}: legacy core is not unlinked before decompression")

required = (
    "await _ensureRealDirectory(configDir)",
    "FileSystemEntity.type(path, followLinks: false)",
    "temp.create(exclusive: true)",
    "_privilegedModeBits",
    "_fileSha256(corePath)",
    "_verifyCoreForExecution()",
)
missing = [token for token in required if token not in source]
if missing:
    raise SystemExit(
        f"{path}: missing core file safety guard(s): {', '.join(missing)}"
    )

if source.count("await _verifyCoreForExecution();") < 3:
    raise SystemExit(f"{path}: not every core execution path is guarded")

if "/usr/bin/pkill" in lifecycle_source or "['-f', _corePath]" in lifecycle_source:
    raise SystemExit(f"{lifecycle_path}: broad pkill core cleanup is forbidden")
for forbidden in (
    "/bin/ps",
    "/bin/kill",
    "Process.start(",
    "Process.killPid",
    "process.kill",
    "terminateMacosCoreProcess",
    "'persistOwnedCoreRecord'",
    "writeAsString('$corePid\\n'",
):
    if forbidden in lifecycle_source:
        raise SystemExit(f"{lifecycle_path}: obsolete PID-only lifecycle remains: {forbidden}")

required_lifecycle = (
    "MethodChannel('ssrvpn/core_process')",
    "'launchOwnedCore'",
    "'ownedCoreStatus'",
    "'terminateOwnedCore'",
    "'terminateOwnedCoreRecord'",
    "'removeOwnedCorePidRecord'",
    "MacosNativeCoreHandle? _clashProcess",
    "String? _corePidRecordContents",
    "await _cancelNativeCoreStatusWatch()",
    "await _terminateOrphanedCores()",
    "_proxyService.recoveryPending",
    "expectedContents': expectedRecord",
    "contents == 'v2 $recordedPid $startSeconds $startMicroseconds\\n'",
)
missing_lifecycle = [
    token for token in required_lifecycle if token not in lifecycle_source
]
if missing_lifecycle:
    raise SystemExit(
        f"{lifecycle_path}: missing process-generation guard(s): "
        + ", ".join(missing_lifecycle)
    )

app_delegate = Path("SSRVPN_MacOS/macos/Runner/AppDelegate.swift").read_text(
    encoding="utf-8"
)
required_native = (
    "func acquireInstanceLease(at url: URL? = nil) -> Bool",
    "flock(descriptor, LOCK_EX | LOCK_NB)",
    "performTerminationCleanupIfLeaseOwner",
    "private let coreProcessOperationQueue = DispatchQueue(",
    "func enqueueCoreProcessOperation(_ operation: @escaping () -> Void)",
    "func performCoreProcessOperationAndWait(_ operation: () -> Void)",
    "override func applicationShouldTerminate(",
    "return .terminateLater",
    "func beginProxyLifecycleTransaction() -> String",
    "func endProxyLifecycleTransaction(token: String) -> Bool",
    "runtimeDirectoryForTermination(proxyStateURL:",
    "terminateOwnedCore(in: runtimeDirectory)",
    "struct CoreProcessIdentity: Equatable",
    "struct CoreProcessGeneration: Equatable",
    "struct CorePidRecord: Equatable",
    "struct CoreLaunchResult: Equatable",
    "struct CoreProcessStatus: Equatable",
    "private final class NativeOwnedCoreProcess",
    "private final class CoreOutputCapture",
    "func launchOwnedCore(",
    "identityPollCount: Int = 51",
    "containLaunchedCoreProcess(process)",
    "containTrackedCoreWithoutRecord(in: directory)",
    '"v2 \\(pid) \\(startSeconds) \\(startMicroseconds)\\n"',
    "proc_pidinfo(pid, PROC_PIDTBSDINFO",
    "proc_pidpath(pid",
    "generationBefore == generationAfter",
    "processInfo.pbi_start_tvsec",
    "record.identity(executablePath: corePath)",
    "canSignalProcess: (Int32, Int32) -> Bool,",
    "expectedPidContents: String",
    "text == expectedContents",
    "Darwin.lstat",
    "O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK",
    "fileInfo.st_size <= 128",
    "O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW",
    ".pending-\\(UUID().uuidString)",
    "writePidRecordAtomically",
    "S_IRUSR | S_IWUSR",
    "UInt32(RENAME_EXCL)",
    "func readProxyStateData(at url: URL) -> Data?",
    "func proxyStatePathEntryExists(at url: URL) -> Bool",
    "fileInfo.st_mode & (S_IWGRP | S_IWOTH) == 0",
    "fileInfo.st_size <= 1_048_576",
    "Proxy restore state has no ownership proof; preserving it",
    "validatedProxyServices(in: root)",
)
missing_native = [token for token in required_native if token not in app_delegate]
if missing_native:
    raise SystemExit(
        "AppDelegate.swift: missing exact owned-core termination guard(s): "
        + ", ".join(missing_native)
    )

main_window = Path("SSRVPN_MacOS/macos/Runner/MainFlutterWindow.swift").read_text(
    encoding="utf-8"
)
required_channel = (
    'name: "ssrvpn/core_process"',
    'call.method == "beginProxyLifecycleTransaction"',
    'call.method == "endProxyLifecycleTransaction"',
    'case "launchOwnedCore"',
    'case "ownedCoreStatus"',
    'case "terminateOwnedCore"',
    'case "terminateOwnedCoreRecord"',
    'case "removeOwnedCorePidRecord"',
)
missing_channel = [token for token in required_channel if token not in main_window]
if missing_channel:
    raise SystemExit(
        "MainFlutterWindow.swift: missing native process channel guard(s): "
        + ", ".join(missing_channel)
    )

channel_cases = (
    "launchOwnedCore",
    "ownedCoreStatus",
    "terminateOwnedCore",
    "terminateOwnedCoreRecord",
    "removeOwnedCorePidRecord",
)
for index, method in enumerate(channel_cases):
    start = main_window.index(f'case "{method}"')
    if index + 1 < len(channel_cases):
        end = main_window.index(f'case "{channel_cases[index + 1]}"', start)
    else:
        end = main_window.index("default:", start)
    if "delegate.enqueueCoreProcessOperation" not in main_window[start:end]:
        raise SystemExit(
            f"MainFlutterWindow.swift: {method} must use the serial core operation queue"
        )

if 'case "persistOwnedCoreRecord"' in main_window:
    raise SystemExit(
        "MainFlutterWindow.swift: obsolete two-step spawn/persist channel remains"
    )

begin_start = main_window.index('call.method == "beginProxyLifecycleTransaction"')
begin_end = main_window.index('call.method == "endProxyLifecycleTransaction"')
if "delegate.performCoreProcessOperationAndWait" not in main_window[begin_start:begin_end]:
    raise SystemExit(
        "MainFlutterWindow.swift: proxy lifecycle begin must publish synchronously"
    )
end_end = main_window.index("guard\n        let arguments", begin_end)
if "delegate.enqueueCoreProcessOperation" not in main_window[begin_end:end_end]:
    raise SystemExit(
        "MainFlutterWindow.swift: proxy lifecycle end must use the serial queue"
    )

awake_body = main_window[main_window.index("override func awakeFromNib()"):]
if awake_body.index("delegate.acquireInstanceLease()") > awake_body.index(
    "FlutterViewController()"
):
    raise SystemExit(
        "MainFlutterWindow.swift: instance lease must precede Flutter engine creation"
    )

termination_body = app_delegate[
    app_delegate.index("override func applicationWillTerminate"):
]
if termination_body.index("performTerminationCleanupIfLeaseOwner") > termination_body.index(
    "restoreSavedProxyState()"
):
    raise SystemExit(
        "AppDelegate.swift: lease ownership must gate termination cleanup"
    )
if termination_body.index("performCoreProcessOperationAndWait") > termination_body.index(
    "restoreSavedProxyState()"
):
    raise SystemExit(
        "AppDelegate.swift: termination must drain core operations before proxy/core cleanup"
    )

proxy_service = Path(
    "SSRVPN_MacOS/lib/services/system_proxy_service.dart"
).read_text(encoding="utf-8")
required_proxy_guards = (
    "Future<bool>? _clearSystemProxyInFlight",
    "return _clearSystemProxyInFlight ??= _runClearSystemProxy()",
    "_clearSystemProxyInFlight = null",
    "FileSystemEntity.type(\n        file.path,\n        followLinks: false",
    "stat.size > _maxStateFileBytes",
    "stat.mode & _groupOrOtherWriteMask != 0",
    "无法确认代理归属，已保留恢复快照并阻止核心清理",
    "_runWithNativeProxyLifecycleLease(",
    "'beginProxyLifecycleTransaction'",
    "'endProxyLifecycleTransaction'",
    "_snapshotMetadataKeys.contains(service)",
    "_validatedSavedServiceStates(raw)",
    "_isValidProxyState(value['web'])",
)
missing_proxy_guards = [
    token for token in required_proxy_guards if token not in proxy_service
]
if missing_proxy_guards:
    raise SystemExit(
        "system_proxy_service.dart: missing fail-closed proxy guard(s): "
        + ", ".join(missing_proxy_guards)
    )

prepare = main_source.index("Future<void> _prepareCoreAssetsAfterProxyRecovery")
install = main_source.index("await _installCoreAsset", prepare)
orphan_cleanup = main_source.index("await _terminateOrphanedCores()", prepare)
if orphan_cleanup > install:
    raise SystemExit(
        f"{path}: orphan identity must be handled before replacing AtlasCore"
    )

print("macOS core privilege guards passed.")
PY

for required in \
  'with administrator privileges' \
  '/usr/bin/osascript' \
  'macos_tun_runner.sh' \
  '.tun-session-request'; do
  if ! grep -R -Fq -- "$required" "${runtime[@]}" "$native" "$runner"; then
    echo "macOS TUN authorization guard failed: missing $required" >&2
    exit 1
  fi
done

if grep -Fq '/usr/bin/nohup' \
    SSRVPN_MacOS/lib/services/macos_tun_session.dart; then
  echo "macOS TUN authorization guard failed: root runner must stay attached" >&2
  exit 1
fi

for required in \
  '[[ ${EUID:-$(id -u)} -eq 0 ]]' \
  'Mihomo core digest mismatch' \
  'the requesting app is not owned by the console user' \
  '/var/run/ssrvpn-tun-$user_id' \
  'kill -0 "$app_pid"' \
  '/var/run/ssrvpn-tun-status-$app_pid' \
  'write_status "error:tun"' \
  'write_status "error:dns"' \
  'write_status "error:stale"' \
  '/usr/sbin/networksetup' \
  '/Library/Application Support/SSRVPN' \
  'lock_dir="/var/run/ssrvpn-tun.lock"' \
  'capture_tun_dns_state' \
  'dns_snapshot_matches' \
  'configure_tun_dns' \
  'restore_persisted_tun_dns' \
  'for _ in {1..24}'; do
  if ! grep -Fq -- "$required" "$runner"; then
    echo "macOS TUN runner guard failed: missing $required" >&2
    exit 1
  fi
done

python3 - <<'PY'
from pathlib import Path

path = Path("SSRVPN_MacOS/assets/macos_tun_runner.sh")
source = path.read_text(encoding="utf-8")

lock = source.index("acquire_tun_lock ||")
restore = source.index("if ! restore_persisted_tun_dns_with_retry", lock)
capture = source.index("if ! capture_tun_dns_state")
core_start = source.index(
    'TMPDIR="$runtime_dir/tmp" "$runtime_core" -d "$runtime_dir"'
)
configure = source.index("if ! configure_tun_dns", core_start)
running = source.index('write_status "running"', configure)
if not restore < capture < core_start < configure < running:
    raise SystemExit(
        f"{path}: DNS recovery/capture/core/configure/running order is unsafe"
    )

journal = 'dns_state_dir="/Library/Application Support/SSRVPN"'
if journal not in source:
    raise SystemExit(f"{path}: DNS recovery journal must survive /var/run cleanup")
if 'dns_state_path="$runtime_dir/' in source:
    raise SystemExit(f"{path}: DNS recovery journal must not live under /var/run")
if 'current != 127.0.0.1' not in source or 'remove_dns_state' not in source:
    raise SystemExit(
        f"{path}: changed user DNS must be preserved and retire stale ownership"
    )
if 'LC_ALL=C' not in source:
    raise SystemExit(f"{path}: networksetup parsing must use a stable locale")
if '/bin/rm -rf "$dns_state_dir"' in source:
    raise SystemExit(f"{path}: runtime cleanup must retain failed DNS recovery state")

apply_body = source[
    source.index("configure_tun_dns()"):
    source.index("restore_persisted_tun_dns()")
]
for guard in ("load_persisted_tun_dns", "network_service_for_device", "dns_snapshot_matches"):
    if guard not in apply_body:
        raise SystemExit(f"{path}: DNS apply is missing pre-mutation guard {guard}")

print("macOS TUN DNS transaction guards passed.")
PY

python3 - <<'PY'
from hashlib import sha256
from pathlib import Path
import re

session_path = Path("SSRVPN_MacOS/lib/services/macos_tun_session.dart")
session = session_path.read_text(encoding="utf-8")
assets = {
    "_runnerSha256": Path("SSRVPN_MacOS/assets/macos_tun_runner.sh"),
    "_coreArchiveSha256": Path("SSRVPN_MacOS/assets/AtlasCore.gz"),
    "_coreManifestSha256": Path("SSRVPN_MacOS/assets/AtlasCore-source.txt"),
}
for constant, path in assets.items():
    match = re.search(
        rf"{constant}\s*=\s*\n?\s*'([0-9a-f]{{64}})'",
        session,
    )
    if match is None:
        raise SystemExit(f"{session_path}: missing pinned digest {constant}")
    actual = sha256(path.read_bytes()).hexdigest()
    if match.group(1) != actual:
        raise SystemExit(
            f"{session_path}: stale {constant}; expected digest for {path} is {actual}"
        )

for token in (
    "/var/run/ssrvpn-tun-launch-$app_pid",
    "check_hash \"$stage/macos_tun_runner.sh\"",
    "check_hash \"$stage/AtlasCore.gz\"",
    "check_hash \"$stage/AtlasCore-source.txt\"",
    "check_hash \"$stage/config.yaml\"",
):
    if token not in session:
        raise SystemExit(f"{session_path}: missing root-owned staging guard: {token}")

print("macOS TUN staged resource digests passed.")
PY

for required in \
  'enableTunOf:' \
  "tunLabel: 'TUN 模式（需管理员权限）'" \
  'onEnableTunChanged:'; do
  if ! grep -Fq -- "$required" "$desktop_home"; then
    echo "macOS TUN UI guard failed: missing $required" >&2
    exit 1
  fi
done

for required in \
  "tunLabel ?? 'TUN 模式'" \
  'onEnableTunChanged'; do
  if ! grep -Fq -- "$required" "$node_selection_controls"; then
    echo "macOS shared TUN control guard failed: missing $required" >&2
    exit 1
  fi
done
