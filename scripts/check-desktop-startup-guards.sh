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
        "_startInternal(startToken)",
        "void _ensureStartCurrent(int startToken)",
        "_startGeneration++",
        "Completer<void>? _startCancellation",
        "cancellation.complete()",
        "cancellation: _startCancellation?.future",
        "final proxyCleared = await _stopInternal()",
        "if (!proxyCleared)",
    ):
        if token not in source:
            raise SystemExit(f"{path}: missing cancellable-start guard {token}")
    if "Future<void>? _exitCleanupOperation" not in source:
        raise SystemExit(f"{path}: unexpected-exit proxy cleanup is not tracked")
    start = source.index("Future<bool> _startInternal(int startToken)")
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

    stop_start = source.index("Future<bool> _stopInternal()")
    stop_end = source.index("void _ensureStartCurrent", stop_start)
    stop_body = source[stop_start:stop_end]
    proxy_clear = stop_body.index("_proxyService.clearSystemProxy()")
    process_kill = stop_body.index(".kill(")
    if proxy_clear > process_kill:
        raise SystemExit(
            f"{path}: kills the core before restoring the system proxy"
        )
    before_kill = stop_body[proxy_clear:process_kill]
    if "if (!proxyCleared)" not in before_kill or "return false" not in before_kill:
        raise SystemExit(
            f"{path}: proxy recovery failure does not keep the core alive"
        )

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
public_ip_actions = Path(
    "packages/ssrvpn_shared/lib/desktop_ui/screens/desktop_home_public_ip_part.dart"
)
for path in (home, runtime_actions, public_ip_actions):
    line_count = len(path.read_text(encoding="utf-8").splitlines())
    if line_count > 900:
        raise SystemExit(f"{path}: shared desktop screen part grew to {line_count} lines")

aggregate_lines = sum(
    len(path.read_text(encoding="utf-8").splitlines())
    for path in (home, runtime_actions)
)
if aggregate_lines > 1250:
    raise SystemExit(
        f"desktop home state/runtime parts grew to {aggregate_lines} aggregate lines"
    )

for entrypoint in (
    Path("SSRVPN_MacOS/lib/screens/home_screen.dart"),
    Path("SSRVPN_Windows/lib/screens/home_screen.dart"),
):
    entrypoint_source = entrypoint.read_text(encoding="utf-8")
    for required_part in (
        "desktop_home_runtime_actions_part.dart",
        "desktop_home_public_ip_part.dart",
    ):
        if required_part not in entrypoint_source:
            raise SystemExit(f"{entrypoint}: missing {required_part}")

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

print("Desktop screen boundary and latency-policy guards passed.")

for app in (
    Path("SSRVPN_MacOS/lib/app.dart"),
    Path("SSRVPN_Windows/lib/app.dart"),
):
    app_source = app.read_text(encoding="utf-8")
    if re.search(r"(?m)^\s*_clashService\?\.stop\(\);\s*$", app_source):
        raise SystemExit(f"{app}: dispose leaks asynchronous stop errors")
    if "Dispose core cleanup failed" not in app_source:
        raise SystemExit(f"{app}: dispose stop failure is not contained")

print("Desktop dispose cleanup guard passed.")
PY
