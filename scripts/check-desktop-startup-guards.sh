#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path

paths = (
    Path("SSRVPN_MacOS/lib/services/clash_service.dart"),
    Path("SSRVPN_Windows/lib/services/clash_service.dart"),
)

for path in paths:
    source = path.read_text(encoding="utf-8")
    if "Future<void>? _exitCleanupOperation" not in source:
        raise SystemExit(f"{path}: unexpected-exit proxy cleanup is not tracked")
    start = source.index("Future<bool> _startInternal()")
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
PY
