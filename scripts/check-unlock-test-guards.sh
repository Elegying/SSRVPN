#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path

screens = (
    Path("SSRVPN_Android/lib/screens/unlock_test_screen.dart"),
    Path("packages/ssrvpn_shared/lib/desktop_ui/screens/desktop_unlock_test_screen_part.dart"),
)
for screen in screens:
    source = screen.read_text(encoding="utf-8")
    for token in (
        "UnlockTestCancellation? _allCancellation",
        "_allCancellation?.cancel()",
        "cancellation: cancellation",
        "on UnlockTestCancelled",
        "label: _isTestingAll ? '取消测试' : '全部测试'",
    ):
        if token not in source:
            raise SystemExit(f"{screen}: missing cancellable unlock audit guard: {token}")
    if "if (_isTestingAll) return" in source:
        raise SystemExit(f"{screen}: bulk unlock audit cannot be cancelled")

service = Path("packages/ssrvpn_shared/lib/services/unlock_test_service.dart").read_text(
    encoding="utf-8"
)
for token in (
    "class UnlockTestCancellation",
    "cancellation.whenCancelled",
    "client.close()",
    "cancellation?.throwIfCancelled()",
):
    if token not in service:
        raise SystemExit(f"unlock service is missing cancellation guard: {token}")

print("Unlock audit cancellation guards passed.")
PY
