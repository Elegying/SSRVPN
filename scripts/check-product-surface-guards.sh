#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path

removed_paths = (
    Path("SSRVPN_Android/lib/screens/unlock_test_screen.dart"),
    Path("SSRVPN_MacOS/lib/screens/unlock_test_screen.dart"),
    Path("SSRVPN_Windows/lib/screens/unlock_test_screen.dart"),
    Path("packages/ssrvpn_shared/lib/desktop_ui/screens/desktop_unlock_test_screen_part.dart"),
    Path("packages/ssrvpn_shared/lib/services/unlock_test_service.dart"),
    Path("packages/ssrvpn_shared/test/unlock_test_service_test.dart"),
)
for path in removed_paths:
    if path.exists():
        raise SystemExit(f"removed unlock-test path still exists: {path}")

source_roots = (
    Path("SSRVPN_Android/lib"),
    Path("SSRVPN_MacOS/lib"),
    Path("SSRVPN_Windows/lib"),
    Path("packages/ssrvpn_shared/lib"),
)
for root in source_roots:
    for path in root.rglob("*.dart"):
        source = path.read_text(encoding="utf-8")
        for token in ("unlock_test", "UnlockTest", "解锁测试"):
            if token in source:
                raise SystemExit(f"unlock-test residue in {path}: {token}")

android_app = Path("SSRVPN_Android/lib/app.dart").read_text(encoding="utf-8")
if android_app.count("NavItem(") != 2:
    raise SystemExit("Android primary navigation must contain exactly two items")
for token in ("label: '主页'", "label: '订阅'", "HomeScreen(key: _homeKey)",
              "const SubscriptionScreen()"):
    if token not in android_app:
        raise SystemExit(f"Android primary navigation is missing: {token}")

desktop_shell = Path(
    "packages/ssrvpn_shared/lib/desktop_ui/desktop_app_shell_part.dart"
).read_text(encoding="utf-8")
if desktop_shell.count("NavItem(") != 2:
    raise SystemExit("Desktop primary navigation must contain exactly two items")
for token in ("label: '首页'", "label: '订阅'", "HomeScreen()",
              "SubscriptionScreen()"):
    if token not in desktop_shell:
        raise SystemExit(f"Desktop primary navigation is missing: {token}")

print("Two-page product surface guards passed.")
PY
