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
        "terminate: terminateCoreProcess",
        "_terminateVerifiedCore(",
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
    "SSRVPN_Windows/lib/services/clash_service_start_preparation.dart"
).read_text(encoding="utf-8")
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

windows_orchestrator = orchestrators[1].read_text(encoding="utf-8")
hidden_title_bar = "windowManager.setTitleBarStyle("
if hidden_title_bar not in windows_orchestrator:
    raise SystemExit("Windows does not hide the native title bar")
title_bar_call = windows_orchestrator.index(hidden_title_bar)
show_call = windows_orchestrator.index("windowManager.show()", title_bar_call)
title_bar_body = windows_orchestrator[title_bar_call:show_call]
for token in ("TitleBarStyle.hidden", "windowButtonVisibility: false"):
    if token not in title_bar_body:
        raise SystemExit(f"Windows native title bar is not fully hidden: {token}")
for token in (
    "TitleBarStyle.normal",
    "windowButtonVisibility: true",
    "Restore native title bar after startup failure failed",
    "Error.throwWithStackTrace(error, stack)",
):
    if token not in windows_orchestrator[title_bar_call:]:
        raise SystemExit(
            f"Windows failed startup cannot restore the native title bar: {token}"
        )

windows_app = Path("SSRVPN_Windows/lib/app.dart").read_text(encoding="utf-8")
if "return WindowsDesktopFrame(child: child);" not in windows_app:
    raise SystemExit("Windows custom title bar wrapper is missing")
if windows_app.count("_withWindowsFrame(status,") < 2:
    raise SystemExit(
        "Windows custom title bar does not wrap both startup and main shells"
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
        "packages/ssrvpn_shared/lib/widgets/ssrvpn_version_update_footer.dart"
    ): 120,
    Path(
        "packages/ssrvpn_shared/lib/widgets/ssrvpn_subscription_error_dialog.dart"
    ): 200,
    Path("packages/ssrvpn_shared/lib/widgets/ssrvpn_home_overview.dart"): 600,
    Path(
        "packages/ssrvpn_shared/lib/widgets/ssrvpn_home_overview_header.dart"
    ): 200,
    Path("packages/ssrvpn_shared/lib/widgets/ssrvpn_node_selection_page.dart"): 360,
    Path("packages/ssrvpn_shared/lib/widgets/ssrvpn_node_selection_controls.dart"): 400,
    Path(
        "packages/ssrvpn_shared/lib/widgets/ssrvpn_node_selection_support_controls.dart"
    ): 200,
    Path(
        "packages/ssrvpn_shared/lib/widgets/ssrvpn_node_selection_subscription_filter.dart"
    ): 220,
    Path("packages/ssrvpn_shared/lib/widgets/ssrvpn_node_selection_node_card.dart"): 250,
    Path("packages/ssrvpn_shared/lib/widgets/ssrvpn_subscription_view.dart"): 600,
    Path(
        "packages/ssrvpn_shared/lib/widgets/ssrvpn_subscription_header.dart"
    ): 100,
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
# Allow the active-page property and shared traffic-panel wiring only;
# sampling and layout remain in the standalone shared widget.
if aggregate_lines > 1410:
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

connect_start = source.index("Future<void> _handleConnectionAction(")
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
for token in (
    "_DesktopConnectionAction.cancelPendingConnection",
    "_DesktopConnectionAction.disconnect",
    "_DesktopConnectionAction.connect",
):
    if token not in source:
        raise SystemExit(f"{home}: missing explicit desktop connection action: {token}")
runtime_source = runtime_actions.read_text(encoding="utf-8")
for path, ui_source in ((home, connect), (runtime_actions, runtime_source)):
    if "verifyUserConnectivity" in ui_source:
        raise SystemExit(
            f"{path}: desktop UI duplicates the service-owned data-plane observation"
        )

data_plane_support_path = Path(
    "packages/ssrvpn_shared/lib/services/clash_service_data_plane_support.dart"
)
data_plane_support = data_plane_support_path.read_text(encoding="utf-8")
base_path = Path("packages/ssrvpn_shared/lib/services/clash_service_base.dart")
base_source = base_path.read_text(encoding="utf-8")
for token in (
    "void onDataPlaneRouteChanged()",
    "if (isRunning) scheduleDataPlaneObservation();",
):
    if token not in data_plane_support:
        raise SystemExit(f"{data_plane_support_path}: missing route observation guard {token}")
switch_start = base_source.index("Future<bool> _switchSelectedProxy(")
switch_end = base_source.index("Future<String?> currentSelectedProxyName()", switch_start)
switch_body = base_source[switch_start:switch_end]
route_change = switch_body.index("onDataPlaneRouteChanged();")
route_notification = switch_body.index("_notifyStatusChanged();")
if route_change > route_notification:
    raise SystemExit(f"{base_path}: route observation starts after status publication")

for path in paths:
    lifecycle = path.read_text(encoding="utf-8")
    for token in (
        "Future<void> observeDataPlaneHealth() async",
        "scheduleDataPlaneObservation();",
    ):
        if token not in lifecycle:
            raise SystemExit(f"{path}: missing service-owned data-plane guard {token}")
if "if (startedWithTun) scheduleDataPlaneObservation();" in windows_source:
    raise SystemExit(
        "Windows system-proxy startup does not schedule a data-plane observation"
    )

print("Desktop connect finalization guard passed.")

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

macos_delegate = Path("SSRVPN_MacOS/macos/Runner/AppDelegate.swift")
macos_core_support = macos_delegate.with_name("CoreProcessSupport.swift")
macos_application_support = macos_delegate.with_name(
    "ApplicationLifecycleSupport.swift"
)
macos_project = Path("SSRVPN_MacOS/macos/Runner.xcodeproj/project.pbxproj")
delegate_source = macos_delegate.read_text(encoding="utf-8")
if len(delegate_source.splitlines()) > 2020:
    raise SystemExit(
        f"{macos_delegate}: native app delegate grew beyond its 2020-line boundary"
    )
if not macos_core_support.is_file():
    raise SystemExit(f"{macos_core_support}: native core support boundary is missing")
core_support_source = macos_core_support.read_text(encoding="utf-8")
if len(core_support_source.splitlines()) > 240:
    raise SystemExit(f"{macos_core_support}: native core support boundary regressed")
if not macos_application_support.is_file():
    raise SystemExit(
        f"{macos_application_support}: application lifecycle support boundary is missing"
    )
if len(macos_application_support.read_text(encoding="utf-8").splitlines()) > 130:
    raise SystemExit(
        f"{macos_application_support}: application lifecycle support boundary regressed"
    )
for delegated_type in (
    "struct CorePidRecord",
    "final class CoreOutputCapture",
    "final class NativeOwnedCoreProcess",
):
    if delegated_type in delegate_source:
        raise SystemExit(
            f"{macos_delegate}: {delegated_type} leaked back into application orchestration"
        )
for delegated_implementation in (
    "protocol WindowRevealTarget",
    "instanceLeaseDescriptor",
    "flock(",
):
    if delegated_implementation in delegate_source:
        raise SystemExit(
            f"{macos_delegate}: {delegated_implementation} leaked back into application orchestration"
        )
for misplaced_type in (
    "struct ProxyCommandResult",
    "class ProxyStateFileSnapshot",
    "enum ApplicationTerminationLeaseState",
):
    if misplaced_type in core_support_source:
        raise SystemExit(
            f"{macos_core_support}: unrelated {misplaced_type} widened the core support boundary"
        )
for private_type in (
    "private final class ProxyStateFileSnapshot",
    "private enum ApplicationTerminationLeaseState",
):
    if private_type not in delegate_source:
        raise SystemExit(
            f"{macos_delegate}: {private_type} must remain private to orchestration"
        )
project_source = macos_project.read_text(encoding="utf-8")
try:
    native_targets = project_source.split(
        "/* Begin PBXNativeTarget section */", 1
    )[1].split("/* End PBXNativeTarget section */", 1)[0]
    sources_phases = project_source.split(
        "/* Begin PBXSourcesBuildPhase section */", 1
    )[1].split("/* End PBXSourcesBuildPhase section */", 1)[0]
    build_files = project_source.split(
        "/* Begin PBXBuildFile section */", 1
    )[1].split("/* End PBXBuildFile section */", 1)[0]
    file_references = project_source.split(
        "/* Begin PBXFileReference section */", 1
    )[1].split("/* End PBXFileReference section */", 1)[0]
except IndexError as error:
    raise SystemExit(f"{macos_project}: required PBX section is missing") from error
runner_target = re.search(
    r"(?ms)^\s*[A-F0-9]+ /\* Runner \*/ = \{\n(?P<body>.*?)^\s*\};",
    native_targets,
)
if runner_target is None:
    raise SystemExit(f"{macos_project}: Runner native target is missing")
runner_phases = re.search(
    r"(?ms)^\s*buildPhases = \(\n(?P<body>.*?)^\s*\);",
    runner_target.group("body"),
)
if runner_phases is None:
    raise SystemExit(f"{macos_project}: Runner build phases are missing")
runner_sources_id = re.search(
    r"(?m)^\s*([A-F0-9]+) /\* Sources \*/,$",
    runner_phases.group("body"),
)
if runner_sources_id is None:
    raise SystemExit(f"{macos_project}: Runner Sources phase is missing")
runner_sources_phase = re.search(
    rf"(?ms)^\s*{runner_sources_id.group(1)} /\* Sources \*/ = \{{\n"
    r"(?P<body>.*?)^\s*\};",
    sources_phases,
)
if runner_sources_phase is None:
    raise SystemExit(f"{macos_project}: Runner Sources phase definition is missing")
for support_name in (
    macos_core_support.name,
    macos_application_support.name,
):
    runner_build_file = re.search(
        rf"(?m)^\s*([A-F0-9]+) /\* {re.escape(support_name)} in Sources \*/,$",
        runner_sources_phase.group("body"),
    )
    if runner_build_file is None:
        raise SystemExit(
            f"{macos_project}: {support_name} is not compiled by the Runner target"
        )
    build_file_definition = re.search(
        rf"(?m)^\s*{runner_build_file.group(1)} /\* {re.escape(support_name)} in Sources \*/ = "
        rf"\{{isa = PBXBuildFile; fileRef = ([A-F0-9]+) /\* {re.escape(support_name)} \*/; \}};",
        build_files,
    )
    if build_file_definition is None:
        raise SystemExit(
            f"{macos_project}: {support_name} Runner build-file mapping is invalid"
        )
    if not re.search(
        rf"(?m)^\s*{build_file_definition.group(1)} /\* {re.escape(support_name)} \*/ = "
        rf"\{{isa = PBXFileReference;[^\n]*path = {re.escape(support_name)};",
        file_references,
    ):
        raise SystemExit(
            f"{macos_project}: {support_name} PBX file reference is missing"
        )
print("macOS native core support boundary guard passed.")

windows_proxy = Path("SSRVPN_Windows/lib/services/system_proxy_service.dart")
windows_proxy_models = windows_proxy.with_name("system_proxy_models.dart")
windows_proxy_source = windows_proxy.read_text(encoding="utf-8")
if len(windows_proxy_source.splitlines()) > 1450:
    raise SystemExit(
        f"{windows_proxy}: proxy transaction orchestration grew beyond its "
        "1450-line boundary"
    )
if "part 'system_proxy_models.dart';" not in windows_proxy_source:
    raise SystemExit(f"{windows_proxy}: missing proxy model boundary")
if not windows_proxy_models.is_file():
    raise SystemExit(f"{windows_proxy_models}: proxy model boundary is missing")
if len(windows_proxy_models.read_text(encoding="utf-8").splitlines()) > 130:
    raise SystemExit(f"{windows_proxy_models}: proxy model boundary regressed")
for delegated_type in (
    "class _SystemProxyAcquisitionCancelled",
    "class _SystemProxyAcquisitionCancellation",
    "enum _ProxyRecoveryAction",
    "class _ProxySnapshot",
    "class _NativeProxyJournal",
):
    if delegated_type in windows_proxy_source:
        raise SystemExit(
            f"{windows_proxy}: {delegated_type} leaked back into transaction orchestration"
        )
print("Windows system proxy model boundary guard passed.")

# The Windows lifecycle part also carries the PowerShell 5.1-compatible,
# handle-based process identity verifier. Keep a small audited headroom without
# forcing security-sensitive native code into an opaque generated asset.
hotspot_limits = {
    Path("SSRVPN_MacOS/lib/services/system_proxy_service.dart"): 1100,
    Path("SSRVPN_Windows/lib/services/clash_service_lifecycle.dart"): 1800,
    Path("SSRVPN_Windows/windows/runner/launcher_main.cpp"): 1500,
    Path("SSRVPN_Windows/installer/program_files_transaction.ps1"): 1600,
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
