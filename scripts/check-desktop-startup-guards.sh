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
PY
