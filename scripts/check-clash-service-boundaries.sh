#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

python3 - <<'PY'
from pathlib import Path

services = {
    Path("packages/ssrvpn_shared/lib/services/clash_service_base.dart"): (
        750,
        (
            "clash_service_config_support.dart",
            "clash_service_diagnostics.dart",
            "clash_service_runtime_support.dart",
        ),
    ),
    Path("SSRVPN_MacOS/lib/services/clash_service.dart"): (
        550,
        ("clash_service_config.dart", "clash_service_lifecycle.dart"),
    ),
    Path("SSRVPN_Windows/lib/services/clash_service.dart"): (
        550,
        ("clash_service_config.dart", "clash_service_lifecycle.dart"),
    ),
}

for path, (limit, parts) in services.items():
    source = path.read_text(encoding="utf-8")
    lines = len(source.splitlines())
    if lines > limit:
        raise SystemExit(f"{path}: {lines} lines exceeds the {limit}-line boundary")
    for part in parts:
        part_path = path.parent / part
        if not part_path.is_file():
            raise SystemExit(f"{path}: missing responsibility part {part}")
        if f"part '{part}';" not in source:
            raise SystemExit(f"{path}: does not declare part '{part}'")

subscription_base = Path(
    "packages/ssrvpn_shared/lib/services/subscription_service_base.dart"
)
subscription_source = subscription_base.read_text(encoding="utf-8")
if len(subscription_source.splitlines()) > 800:
    raise SystemExit(f"{subscription_base}: subscription orchestration boundary regressed")
if "subscription_node_codec.dart" not in subscription_source:
    raise SystemExit(f"{subscription_base}: node codec responsibility is not delegated")
if "_cleanJsonMap" in subscription_source:
    raise SystemExit(f"{subscription_base}: node normalization leaked back into orchestration")

macos_settings = Path("SSRVPN_MacOS/lib/services/settings_service.dart")
macos_settings_source = macos_settings.read_text(encoding="utf-8")
if len(macos_settings_source.splitlines()) > 680:
    raise SystemExit(f"{macos_settings}: settings orchestration boundary regressed")
macos_store = macos_settings.with_name("macos_private_file_store.dart")
if not macos_store.is_file():
    raise SystemExit(f"{macos_settings}: missing private file-store responsibility")
if "part 'macos_private_file_store.dart';" not in macos_settings_source:
    raise SystemExit(f"{macos_settings}: private file-store part is not declared")

for platform in ("SSRVPN_MacOS", "SSRVPN_Windows"):
    service = Path(platform) / "lib/services/clash_service.dart"
    lifecycle = service.with_name("clash_service_lifecycle.dart")
    main_source = service.read_text(encoding="utf-8")
    lifecycle_source = lifecycle.read_text(encoding="utf-8")
    for call in ("setSystemProxy", "clearSystemProxy"):
        if call in main_source:
            raise SystemExit(f"{service}: system proxy call {call} leaked into main service")
        if call not in lifecycle_source:
            raise SystemExit(f"{lifecycle}: missing system proxy call {call}")

geo_sources = [
    *Path("packages/ssrvpn_shared/lib").rglob("*.dart"),
    *Path("SSRVPN_Android/lib").rglob("*.dart"),
    *Path("SSRVPN_MacOS/lib").rglob("*.dart"),
    *Path("SSRVPN_Windows/lib").rglob("*.dart"),
]
for source_path in geo_sources:
    if "http://ip-api.com" in source_path.read_text(encoding="utf-8"):
        raise SystemExit(f"{source_path}: cleartext external Geo lookup remains")

print("Clash service responsibility boundaries passed.")
PY
