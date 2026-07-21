#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import re
from pathlib import Path

paths = (
    Path("SSRVPN_MacOS/lib/services/clash_service_lifecycle.dart"),
    Path("SSRVPN_Windows/lib/services/clash_service_lifecycle.dart"),
)

for path in paths:
    source = path.read_text(encoding="utf-8")
    for token in (
        "int _startGeneration = 0",
        "void _ensureStartCurrent(int startToken)",
        "_startGeneration++",
        "Completer<void>? _startCancellation",
        "cancellation.complete()",
        "cancellation: _startCancellation?.future",
        "if (!proxyCleared)",
    ):
        if token not in source:
            raise SystemExit(f"{path}: missing cancellable-start guard {token}")
    start_match = re.search(
        r"Future<bool>\s+_startInternal\s*\(\s*int\s+startToken\b", source
    )
    call_match = re.search(r"_startInternal\s*\(\s*startToken\b", source)
    if start_match is None or call_match is None:
        raise SystemExit(f"{path}: missing cancellable-start guard _startInternal")
    if re.search(r"final\s+\w+\s*=\s*await\s+_stopInternal\(\)", source) is None:
        raise SystemExit(f"{path}: stop does not await cancellable startup cleanup")
    if "Future<void>? _exitCleanupOperation" not in source:
        raise SystemExit(f"{path}: unexpected-exit proxy cleanup is not tracked")
    start = start_match.start()
    end = source.index("Future<void> stop()", start)
    body = source[start:end]
    proxy_write = body.index("_proxyService.setSystemProxy")
    running_commit = body.index("setRunning(true)")
    if running_commit < proxy_write:
        raise SystemExit(
            f"{path}: running state is committed before the system proxy write"
        )

    post_proxy = body[proxy_write:running_commit]
    required = (
        "startupExitCode == null",
        "identical(",
        "startedProcess",
        "await healthCheck()",
    )
    missing = [token for token in required if token not in post_proxy]
    if missing:
        raise SystemExit(
            f"{path}: missing post-proxy process guard(s): {', '.join(missing)}"
        )

    stop_start = source.index("Future<bool> _stopInternal(")
    stop_end_candidates = [
        source.find(marker, stop_start + 1)
        for marker in ("void _ensureStartCurrent", "Future<bool> _startTunCore")
    ]
    stop_end = min(index for index in stop_end_candidates if index >= 0)
    stop_body = source[stop_start:stop_end]
    proxy_clear = stop_body.index("_proxyService.clearSystemProxy()")
    termination_calls = (
        "terminateCoreProcess(coreProcess)",
        "terminateMacosCoreProcess(",
        "'terminateOwnedCoreRecord'",
        ".kill(",
    )
    process_kill = min(
        stop_body.index(call) for call in termination_calls if call in stop_body
    )
    if proxy_clear > process_kill:
        raise SystemExit(
            f"{path}: kills the core before restoring the system proxy"
        )
    before_kill = stop_body[proxy_clear:process_kill]
    unsafe_endpoint_guard = (
        "if (!proxyCleared)" in before_kill
        or "ProxyRecoveryDisposition.endpointMayStillBeOwned" in before_kill
    )
    if not unsafe_endpoint_guard or "return false" not in before_kill:
        raise SystemExit(
            f"{path}: proxy recovery failure does not keep the core alive"
        )
    if "setRunning(false)" not in before_kill or "notifyStatusChanged()" not in before_kill:
        raise SystemExit(
            f"{path}: released proxy endpoint does not immediately publish disconnected state"
        )

windows_source = paths[1].read_text(encoding="utf-8")
windows_source += Path(
    "SSRVPN_Windows/lib/services/clash_service_tun_recovery.dart"
).read_text(encoding="utf-8")
required_tun_guards = (
    "Future<bool> healthCheck() async",
    "final tun = (await getConfigs())?['tun']",
    "tun['enable'] != true",
    "probeWindowsTunRuntime(",
    "WindowsTunRuntimeStatus.ready",
    "if (isAdministrator != true)",
)
missing = [token for token in required_tun_guards if token not in windows_source]
if missing:
    raise SystemExit(
        "Windows TUN startup is not fail-closed: " + ", ".join(missing)
    )
if "if (isAdministrator == null)" in windows_source:
    raise SystemExit("Windows TUN administrator probe still fails open")

windows_start = windows_source.index("Future<bool> _startInternal(")
windows_stop = windows_source.index("Future<void> stop()", windows_start)
windows_start_body = windows_source[windows_start:windows_stop]
process_spawn = windows_start_body.index(
    "final startedProcess = await Process.start("
)
if windows_start_body[:process_spawn].count("if (_coreProcess != null)") < 2:
    raise SystemExit(
        "Windows can spawn a new core while an old process is still tracked"
    )
if windows_start_body.count("await _cleanupFailedStart()") < 5:
    raise SystemExit("Windows startup failure does not propagate cleanup failure")
if "Future<void>? _pidCleanupOperation" not in windows_source:
    raise SystemExit("Windows exited-core PID cleanup is not tracked")
if "unawaited(_deleteCorePid())" in windows_source:
    raise SystemExit("Windows exited-core PID cleanup can race a new PID write")
if "if (pidCleanup != null) await pidCleanup" not in windows_start_body:
    raise SystemExit("Windows startup does not await the previous PID cleanup")
windows_stop_internal = windows_source.index("Future<bool> _stopInternal(")
windows_stop_internal_end = windows_source.index(
    "void _ensureStartCurrent", windows_stop_internal
)
if (
    "if (pidCleanup != null) await pidCleanup"
    not in windows_source[windows_stop_internal:windows_stop_internal_end]
):
    raise SystemExit("Windows stop does not await an exited-core PID cleanup")

helper_start = windows_source.index("Future<bool> terminateCoreProcess(")
helper_end = windows_source.index("mixin _WindowsCoreLifecycle", helper_start)
helper = windows_source[helper_start:helper_end]
required_termination_guards = (
    "ProcessSignal.sigterm",
    "exitCode.timeout(gracefulTimeout)",
    "ProcessSignal.sigkill",
    "exitCode.timeout(forcedTimeout)",
    "return false",
)
missing = [token for token in required_termination_guards if token not in helper]
if missing:
    raise SystemExit(
        "Windows core termination does not wait after SIGKILL: "
        + ", ".join(missing)
    )
positions = [helper.index(token) for token in required_termination_guards[:4]]
if positions != sorted(positions):
    raise SystemExit("Windows core termination signal/wait order is unsafe")

macos_source = paths[0].read_text(encoding="utf-8")
macos_start = macos_source[
    macos_source.index("Future<bool> _startInternal(") :
    macos_source.index("Future<void> stop()")
]
for token in ("'launchOwnedCore'", "_readNativeCoreStatus(startedProcess)"):
    if token not in macos_start:
        raise SystemExit(
            f"macOS startup is missing native atomic launch/status guard: {token}"
        )
macos_stop = macos_source[
    macos_source.index("Future<bool> _stopInternal(") :
    macos_source.index("Future<bool> _startTunCore")
]
for token in (
    "'terminateOwnedCoreRecord'",
    "'expectedContents': expectedRecord",
    "await _cancelNativeCoreStatusWatch()",
    "if (!terminated)",
):
    if token not in macos_stop:
        raise SystemExit(
            f"macOS normal stop is missing native full-record guard: {token}"
        )
for forbidden in (
    "terminateMacosCoreProcess(",
    "Process.start(",
    "'persistOwnedCoreRecord'",
    "process.kill",
    "Process.killPid",
):
    if forbidden in macos_source:
        raise SystemExit(f"macOS PID-only termination remains: {forbidden}")
if macos_stop.index("if (!terminated)") > macos_stop.index("_clashProcess = null"):
    raise SystemExit("macOS drops core ownership before confirming process exit")

print("Desktop core startup ordering guards passed.")

orchestrators = (
    Path("SSRVPN_MacOS/lib/startup/startup_orchestrator.dart"),
    Path("SSRVPN_Windows/lib/startup/startup_orchestrator.dart"),
)

for path in orchestrators:
    source = path.read_text(encoding="utf-8")
    start = source.index("Future<void> start()")
    run_step = source.index("Future<void> runStep(", start)
    start_body = source[start:run_step]
    core_step = start_body.index("'mihomo_core'")
    core_step_end = start_body.index(");", core_step)
    if "timeout: null" not in start_body[core_step:core_step_end]:
        raise SystemExit(
            f"{path}: core initialization has a non-cancelling outer timeout"
        )

    init_start = source.index("Future<void> initCoreService()")
    init_end = source.index("Future<bool> _intersectsAnyDisplay", init_start)
    init_body = source[init_start:init_end]
    if init_body.index("StartupStatus.instance.setServices") < init_body.index(
        "await core.init"
    ):
        raise SystemExit(
            f"{path}: services are published before core initialization completes"
        )

print("Desktop orchestration publication guards passed.")

home = Path(
    "packages/ssrvpn_shared/lib/desktop_ui/screens/desktop_home_screen_part.dart"
)
runtime_actions = Path(
    "packages/ssrvpn_shared/lib/desktop_ui/screens/desktop_home_runtime_actions_part.dart"
)
background_tasks = Path(
    "packages/ssrvpn_shared/lib/desktop_ui/screens/desktop_home_background_tasks_part.dart"
)
initial_subscription = Path(
    "packages/ssrvpn_shared/lib/desktop_ui/screens/desktop_home_initial_subscription_part.dart"
)
public_ip_actions = Path(
    "packages/ssrvpn_shared/lib/desktop_ui/screens/desktop_home_public_ip_part.dart"
)
part_limits = {
    home: 900,
    runtime_actions: 600,
    background_tasks: 300,
    initial_subscription: 300,
    public_ip_actions: 600,
    Path("packages/ssrvpn_shared/lib/widgets/ssrvpn_app_surface.dart"): 400,
    Path(
        "packages/ssrvpn_shared/lib/widgets/ssrvpn_subscription_error_dialog.dart"
    ): 200,
    Path("packages/ssrvpn_shared/lib/widgets/ssrvpn_home_overview.dart"): 600,
    Path("packages/ssrvpn_shared/lib/widgets/ssrvpn_node_selection_page.dart"): 360,
    Path("packages/ssrvpn_shared/lib/widgets/ssrvpn_node_selection_controls.dart"): 400,
    Path("packages/ssrvpn_shared/lib/widgets/ssrvpn_node_selection_node_card.dart"): 250,
    Path("packages/ssrvpn_shared/lib/widgets/ssrvpn_subscription_view.dart"): 600,
    Path(
        "packages/ssrvpn_shared/lib/desktop_ui/screens/desktop_subscription_screen_part.dart"
    ): 450,
}
for path, limit in part_limits.items():
    if not path.is_file():
        raise SystemExit(f"{path}: shared desktop screen part is missing")
    line_count = len(path.read_text(encoding="utf-8").splitlines())
    if line_count > limit:
        raise SystemExit(
            f"{path}: shared desktop screen part grew to {line_count} lines"
        )

aggregate_lines = sum(
    len(path.read_text(encoding="utf-8").splitlines())
    for path in (home, runtime_actions, background_tasks)
)
if aggregate_lines > 1400:
    raise SystemExit(
        f"desktop home state/runtime/background parts grew to {aggregate_lines} aggregate lines"
    )

for entrypoint in (
    Path("SSRVPN_MacOS/lib/screens/home_screen.dart"),
    Path("SSRVPN_Windows/lib/screens/home_screen.dart"),
):
    entrypoint_source = entrypoint.read_text(encoding="utf-8")
    for required_part in (
        "desktop_home_runtime_actions_part.dart",
        "desktop_home_initial_subscription_part.dart",
        "desktop_home_background_tasks_part.dart",
        "desktop_home_public_ip_part.dart",
        "desktop_force_proxy_sites_dialog_part.dart",
        "desktop_home_dialogs_part.dart",
    ):
        if required_part not in entrypoint_source:
            raise SystemExit(f"{entrypoint}: missing {required_part}")
    for legacy_part in (
        "desktop_home_dashboard_part.dart",
        "desktop_home_status_widgets_part.dart",
        "desktop_home_connection_options_part.dart",
        "desktop_home_node_list_part.dart",
    ):
        if legacy_part in entrypoint_source:
            raise SystemExit(f"{entrypoint}: legacy presentation part is still active: {legacy_part}")

for entrypoint in (
    Path("SSRVPN_MacOS/lib/screens/subscription_screen.dart"),
    Path("SSRVPN_Windows/lib/screens/subscription_screen.dart"),
):
    entrypoint_source = entrypoint.read_text(encoding="utf-8")
    if "desktop_subscription_screen_part.dart" not in entrypoint_source:
        raise SystemExit(f"{entrypoint}: missing shared subscription screen adapter")
    if "desktop_subscription_sections_part.dart" in entrypoint_source:
        raise SystemExit(f"{entrypoint}: legacy subscription sections are still active")

source = home.read_text(encoding="utf-8")
start = source.index("Future<void> _applyNetworkSetting(")
end = source.index("Future<void> _showForceProxySitesDialog", start)
body = source[start:end]
required = ("try {", "catch (", "finally {", "_isConnecting = false")
missing = [token for token in required if token not in body]
if missing:
    raise SystemExit(
        f"{home}: network-setting busy state is not exception-safe: "
        + ", ".join(missing)
    )

print("Desktop network-setting recovery guard passed.")

connect_start = source.index("Future<void> _handleConnectToggle()")
connect_end = source.index("@override\n  Widget build", connect_start)
connect = source[connect_start:connect_end]
for token in ("断开连接失败", "finally {"):
    if token not in connect:
        raise SystemExit(f"{home}: disconnect UI is not recovery-safe: {token}")
if "if (_isConnecting) return" in connect:
    raise SystemExit(f"{home}: connecting state cannot be cancelled from the UI")
for token in ("取消连接失败", "requestConnectionIntent(false)"):
    if token not in connect:
        raise SystemExit(f"{home}: missing desktop cancellation guard: {token}")
verification = connect.index("verifyUserConnectivity")
connected_commit = connect.index("_isConnected = true")
if connected_commit > verification:
    raise SystemExit(
        f"{home}: successful connection remains hidden behind advisory validation"
    )
finalization = connect[verification:]
for token in ("!clashService.isRunning", "isConnectionIntentCurrent"):
    if token not in finalization:
        raise SystemExit(
            f"{home}: desktop connect finalization lacks {token} guard"
        )

print("Desktop connect finalization guard passed.")

runtime_source = runtime_actions.read_text(encoding="utf-8")
if runtime_source.count("await clashService.testAllLatencies") != 1:
    raise SystemExit(f"{runtime_actions}: batch latency workflow is duplicated")
for token in (
    "PrivateNodeLatencyPolicy.displayLatencyForNode(",
    "random: math.Random(),",
):
    if token not in runtime_source:
        raise SystemExit(f"{runtime_actions}: private-node latency policy changed: {token}")

print("Shared desktop surface boundary and latency-policy guards passed.")

coordinator = Path(
    "packages/ssrvpn_shared/lib/services/desktop_connection_coordinator.dart"
)
if not coordinator.is_file():
    raise SystemExit(f"{coordinator}: shared desktop connection coordinator is missing")
coordinator_lines = len(coordinator.read_text(encoding="utf-8").splitlines())
if coordinator_lines > 180:
    raise SystemExit(
        f"{coordinator}: shared desktop connection coordinator grew to "
        f"{coordinator_lines} lines"
    )
for consumer in (
    home,
    runtime_actions,
    Path("SSRVPN_MacOS/lib/app_runtime_actions_part.dart"),
    Path("SSRVPN_Windows/lib/app_runtime_actions_part.dart"),
):
    consumer_source = consumer.read_text(encoding="utf-8")
    if "DesktopConnectionCoordinator().connect(" not in consumer_source:
        raise SystemExit(
            f"{consumer}: bypasses the shared revision-guarded connection transaction"
        )

print("Desktop connection coordinator boundary guard passed.")

for app in (
    Path("SSRVPN_MacOS/lib/app.dart"),
    Path("SSRVPN_Windows/lib/app.dart"),
):
    app_source = app.read_text(encoding="utf-8")
    app_lines = len(app_source.splitlines())
    if app_lines > 620:
        raise SystemExit(f"{app}: application entrypoint grew to {app_lines} lines")
    if "desktop_app_shell_part.dart" not in app_source:
        raise SystemExit(f"{app}: missing shared desktop application shell part")
    if re.search(r"(?m)^\s*_clashService\?\.stop\(\);\s*$", app_source):
        raise SystemExit(f"{app}: dispose leaks asynchronous stop errors")
    if "Dispose core cleanup failed" not in app_source:
        raise SystemExit(f"{app}: dispose stop failure is not contained")

print("Desktop dispose cleanup guard passed.")

for app_dir in (Path("SSRVPN_MacOS/lib"), Path("SSRVPN_Windows/lib")):
    entrypoint = (app_dir / "app.dart").read_text(encoding="utf-8")
    runtime_part = app_dir / "app_runtime_actions_part.dart"
    if "part 'app_runtime_actions_part.dart';" not in entrypoint:
        raise SystemExit(f"{app_dir / 'app.dart'}: missing app runtime actions part")
    if not runtime_part.is_file():
        raise SystemExit(f"{runtime_part}: platform runtime actions part is missing")
    runtime_lines = len(runtime_part.read_text(encoding="utf-8").splitlines())
    if runtime_lines > 320:
        raise SystemExit(
            f"{runtime_part}: platform runtime actions grew to {runtime_lines} lines"
        )

print("Desktop application runtime boundary guard passed.")

app_shell = Path(
    "packages/ssrvpn_shared/lib/desktop_ui/desktop_app_shell_part.dart"
)
if not app_shell.is_file():
    raise SystemExit(f"{app_shell}: shared desktop application shell is missing")
if len(app_shell.read_text(encoding="utf-8").splitlines()) > 620:
    raise SystemExit(f"{app_shell}: shared desktop application shell is oversized")
print("Desktop application shell boundary guard passed.")

hotspot_limits = {
    Path("SSRVPN_Windows/lib/services/clash_service_lifecycle.dart"): 1300,
    Path("SSRVPN_Windows/windows/runner/launcher_main.cpp"): 1500,
    Path("SSRVPN_Windows/installer/stop_ssrvpn_processes.ps1"): 1350,
}
for path, limit in hotspot_limits.items():
    line_count = len(path.read_text(encoding="utf-8").splitlines())
    if line_count > limit:
        raise SystemExit(
            f"{path}: recovery hotspot grew to {line_count} lines; "
            f"split responsibility before exceeding {limit}"
        )
print("Desktop recovery hotspot size guards passed.")
PY
