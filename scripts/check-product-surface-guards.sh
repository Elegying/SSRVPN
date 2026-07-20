#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
import re
from pathlib import Path


def read_source(path: Path) -> str:
    if not path.is_file():
        raise SystemExit(f"required product-surface source is missing: {path}")
    return path.read_text(encoding="utf-8")


def source_section(
    source: str,
    path: Path,
    start_token: str,
    end_token=None,
) -> str:
    try:
        start = source.index(start_token)
        end = len(source) if end_token is None else source.index(end_token, start)
    except ValueError as error:
        raise SystemExit(f"{path}: cannot isolate product-surface section: {error}")
    return source[start:end]

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

legacy_surface_paths = (
    Path("SSRVPN_Android/lib/screens/home_dashboard_part.dart"),
    Path("SSRVPN_Android/lib/widgets/connection_button.dart"),
    Path("SSRVPN_Android/lib/widgets/home_node_list.dart"),
    Path("SSRVPN_Android/lib/widgets/liquid_glass.dart"),
    Path("SSRVPN_Android/lib/widgets/node_list_tile.dart"),
    Path("SSRVPN_Android/lib/widgets/proxy_mode_selector.dart"),
    Path("SSRVPN_Android/lib/widgets/subscription_screen_sections.dart"),
    Path("SSRVPN_MacOS/lib/widgets/connection_button.dart"),
    Path("SSRVPN_MacOS/lib/widgets/liquid_glass.dart"),
    Path("SSRVPN_Windows/lib/widgets/connection_button.dart"),
    Path("SSRVPN_Windows/lib/widgets/liquid_glass.dart"),
    Path("packages/ssrvpn_shared/lib/desktop_ui/widgets/connection_button_part.dart"),
    Path(
        "packages/ssrvpn_shared/lib/desktop_ui/widgets/desktop_home_connection_options_part.dart"
    ),
    Path(
        "packages/ssrvpn_shared/lib/desktop_ui/widgets/desktop_home_dashboard_part.dart"
    ),
    Path(
        "packages/ssrvpn_shared/lib/desktop_ui/widgets/desktop_home_node_list_part.dart"
    ),
    Path(
        "packages/ssrvpn_shared/lib/desktop_ui/widgets/desktop_home_status_widgets_part.dart"
    ),
    Path(
        "packages/ssrvpn_shared/lib/desktop_ui/widgets/desktop_subscription_sections_part.dart"
    ),
    Path("packages/ssrvpn_shared/lib/desktop_ui/widgets/liquid_glass_part.dart"),
)
for path in legacy_surface_paths:
    if path.exists():
        raise SystemExit(f"legacy product-surface path still exists: {path}")

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

android_app_path = Path("SSRVPN_Android/lib/app.dart")
android_app = read_source(android_app_path)
for token in (
    "PageView(",
    "HomeScreen(key: _homeKey)",
    "const SubscriptionScreen()",
    "SsrvpnBottomNavigation(",
    "version: AppConstants.appVersion",
):
    if token not in android_app:
        raise SystemExit(f"{android_app_path}: Android two-page shell is missing {token}")
if "NavItem(" in android_app:
    raise SystemExit(f"{android_app_path}: legacy Android navigation is still active")

desktop_shell_path = Path(
    "packages/ssrvpn_shared/lib/desktop_ui/desktop_app_shell_part.dart"
)
desktop_shell = read_source(desktop_shell_path)
for token in (
    "IndexedStack(",
    "HomeScreen()",
    "SubscriptionScreen()",
    "SsrvpnBottomNavigation(",
    "version: AppConstants.appVersion",
):
    if token not in desktop_shell:
        raise SystemExit(f"{desktop_shell_path}: desktop two-page shell is missing {token}")
if "NavItem(" in desktop_shell:
    raise SystemExit(f"{desktop_shell_path}: legacy desktop navigation is still active")

app_surface_path = Path("packages/ssrvpn_shared/lib/widgets/ssrvpn_app_surface.dart")
app_surface = read_source(app_surface_path)
bottom_navigation = source_section(
    app_surface,
    app_surface_path,
    "class SsrvpnBottomNavigation",
    "class SsrvpnNavigationDestination",
)
destination_count = len(
    re.findall(r"\bchild:\s*SsrvpnNavigationDestination\(", bottom_navigation)
)
if destination_count != 2:
    raise SystemExit(
        f"{app_surface_path}: bottom navigation must contain exactly two destinations"
    )
for token in (
    "key: const Key('ssrvpn-bottom-navigation')",
    "label: '主页'",
    "onTap: () => onTap(0)",
    "label: '订阅'",
    "onTap: () => onTap(1)",
    "'版本号：$version'",
):
    if token not in app_surface:
        raise SystemExit(f"{app_surface_path}: shared navigation is missing {token}")
for token in ("关于", "about"):
    if token in bottom_navigation.casefold():
        raise SystemExit(
            f"{app_surface_path}: About must not appear inside bottom navigation"
        )

shared_exports_path = Path("packages/ssrvpn_shared/lib/ssrvpn_shared.dart")
shared_exports = read_source(shared_exports_path)
shared_surface_paths = {
    Path("packages/ssrvpn_shared/lib/widgets/ssrvpn_home_overview.dart"):
        "class SsrvpnHomeOverview",
    Path("packages/ssrvpn_shared/lib/widgets/ssrvpn_node_selection_page.dart"):
        "class SsrvpnNodeSelectionPage",
    Path("packages/ssrvpn_shared/lib/widgets/ssrvpn_subscription_view.dart"):
        "class SsrvpnSubscriptionView",
}
for path, class_token in shared_surface_paths.items():
    source = read_source(path)
    if class_token not in source:
        raise SystemExit(f"{path}: missing shared surface {class_token}")
    export_token = f"export 'widgets/{path.name}';"
    if export_token not in shared_exports:
        raise SystemExit(f"{shared_exports_path}: missing {export_token}")
if "export 'widgets/ssrvpn_app_surface.dart';" not in shared_exports:
    raise SystemExit(f"{shared_exports_path}: shared app surface is not exported")

android_home_path = Path("SSRVPN_Android/lib/screens/home_screen.dart")
android_home_policy_path = Path(
    "SSRVPN_Android/lib/screens/home_connection_status_policy.dart"
)
desktop_home_path = Path(
    "packages/ssrvpn_shared/lib/desktop_ui/screens/desktop_home_screen_part.dart"
)
android_home = read_source(android_home_path)
android_home_policy = read_source(android_home_policy_path)
desktop_home = read_source(desktop_home_path)
for path, source in (
    (android_home_path, android_home),
    (desktop_home_path, desktop_home),
):
    for token in ("SsrvpnHomeOverview(", "SsrvpnNodeSelectionPage("):
        if token not in source:
            raise SystemExit(f"{path}: platform Home bypasses shared surface {token}")

home_overview_path = Path(
    "packages/ssrvpn_shared/lib/widgets/ssrvpn_home_overview.dart"
)
home_overview = read_source(home_overview_path)
home_about_guards = (
    (app_surface_path, app_surface, ("showSsrvpnAboutDialog",)),
    (
        home_overview_path,
        home_overview,
        ("onShowAbout", "ssrvpn-about-button", "Text('关于')"),
    ),
    (android_home_path, android_home, ("onShowAbout", "showSsrvpnAboutDialog")),
    (desktop_home_path, desktop_home, ("onShowAbout", "showSsrvpnAboutDialog")),
)
for path, source, tokens in home_about_guards:
    for token in tokens:
        if token not in source:
            raise SystemExit(f"{path}: Home About entry is missing {token}")

for path in (
    Path("SSRVPN_Android/lib/screens/subscription_screen.dart"),
    Path(
        "packages/ssrvpn_shared/lib/desktop_ui/screens/desktop_subscription_screen_part.dart"
    ),
    Path("packages/ssrvpn_shared/lib/widgets/ssrvpn_subscription_view.dart"),
):
    source = read_source(path)
    normalized = source.casefold()
    for token in ("关于", "about"):
        if token in normalized:
            raise SystemExit(f"{path}: subscription About entry remains: {token}")

android_build = source_section(
    android_home,
    android_home_path,
    "Widget build(BuildContext context)",
    "Future<void> _openNodeSelection() async",
)
android_node_selection = source_section(
    android_home,
    android_home_path,
    "Future<void> _openNodeSelection() async",
    "class _TutorialStepData",
)
desktop_build = source_section(
    desktop_home,
    desktop_home_path,
    "Widget build(BuildContext context)",
    "Future<void> _openNodeSelection() async",
)
desktop_node_selection = source_section(
    desktop_home,
    desktop_home_path,
    "Future<void> _openNodeSelection() async",
)
offline_selection_guards = (
    (
        android_home_path,
        "Home build",
        android_build,
        (
            "HomeNodeController.resolveDefaultNodeFrom(",
            "resolveAndroidPreferredNodeName(",
        ),
    ),
    (
        android_home_path,
        "node-selection route",
        android_node_selection,
        (
            "selectedNodeNameOf:",
            "HomeNodeController.resolveDefaultNodeFrom(",
            "resolveAndroidPreferredNodeName(",
            "!_isConnected || _latencyController.canSelect(node)",
        ),
    ),
    (
        desktop_home_path,
        "Home build",
        desktop_build,
        (
            "HomeNodeController.resolveDefaultNodeFrom(",
            "_disconnectedPreferredNodeName ?? settings.lastSelectedNodeName",
        ),
    ),
    (
        desktop_home_path,
        "node-selection route",
        desktop_node_selection,
        (
            "selectedNodeNameOf:",
            "HomeNodeController.resolveDefaultNodeFrom(",
            "_disconnectedPreferredNodeName ??",
            "settings.lastSelectedNodeName",
            "!_isConnected || _latencyController.canSelect(node)",
        ),
    ),
)
for path, section_name, source, tokens in offline_selection_guards:
    for token in tokens:
        if token not in source:
            raise SystemExit(
                f"{path}: {section_name} offline preselection is missing {token}"
            )

for token in (
    "String? resolveAndroidPreferredNodeName(",
    "selectedNodeName ?? rememberedNodeName",
):
    if token not in android_home_policy:
        raise SystemExit(
            f"{android_home_policy_path}: preferred-node policy is missing {token}"
        )

node_selection_path = Path(
    "packages/ssrvpn_shared/lib/widgets/ssrvpn_node_selection_page.dart"
)
node_selection = read_source(node_selection_path)
for token in ("widget.canSelectNode", "widget.onSelectNode(node)"):
    if token not in node_selection:
        raise SystemExit(f"{node_selection_path}: node selection is missing {token}")

subscription_consumers = (
    Path("SSRVPN_Android/lib/screens/subscription_screen.dart"),
    Path(
        "packages/ssrvpn_shared/lib/desktop_ui/screens/desktop_subscription_screen_part.dart"
    ),
)
for path in subscription_consumers:
    if "SsrvpnSubscriptionView(" not in read_source(path):
        raise SystemExit(f"{path}: subscription UI bypasses the shared view")

print("Shared two-page product surface guards passed.")
PY
