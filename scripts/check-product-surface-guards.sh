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

current_docs = (
    Path("docs/USER_GUIDE.zh-CN.md"),
    Path("docs/TROUBLESHOOTING.zh-CN.md"),
    Path("docs/TESTING.md"),
    Path("SSRVPN_Windows/DESIGN.md"),
)
for path in current_docs:
    source = path.read_text(encoding="utf-8")
    for token in ("unlock", "解锁"):
        if token in source.casefold():
            raise SystemExit(f"unlock-test residue in current documentation {path}: {token}")

windows_safe_mode = Path("SSRVPN_Windows/ssrvpn_safe_mode.bat").read_text(
    encoding="utf-8"
)
if "解压 ZIP" in windows_safe_mode:
    raise SystemExit("Windows installer payload still tells users to extract a ZIP")

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

home_title_sources = (
    Path("SSRVPN_Android/lib/screens/home_dashboard_part.dart"),
    Path("packages/ssrvpn_shared/lib/desktop_ui/widgets/desktop_home_dashboard_part.dart"),
)
for path in home_title_sources:
    source = path.read_text(encoding="utf-8")
    if "AppTitleWithVersion(" not in source:
        raise SystemExit(f"home title must show the synchronized app version: {path}")

print("Two-page product surface guards passed.")
PY
