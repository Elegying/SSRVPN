#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

python3 - <<'PY'
from pathlib import Path

services = {
    Path("packages/ssrvpn_shared/lib/services/clash_service_base.dart"): (
        750,
        ("clash_service_config_support.dart", "clash_service_runtime_support.dart"),
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
