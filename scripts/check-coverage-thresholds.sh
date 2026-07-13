#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

targets=("$@")
if [[ "${#targets[@]}" -eq 0 ]]; then
  targets=(packages/ssrvpn_shared SSRVPN_Android SSRVPN_MacOS SSRVPN_Windows)
fi

python3 - "$@" <<'PY'
import json
from pathlib import Path
import sys

thresholds = {
    "packages/ssrvpn_shared": 65.0,
    "SSRVPN_Android": 50.0,
    "SSRVPN_MacOS": 30.0,
    "SSRVPN_Windows": 30.0,
}

targets = sys.argv[1:] or list(thresholds)
failed = False

def read_lcov(path):
    found = hit = 0
    for line in path.read_text(errors="ignore").splitlines():
        if line.startswith("LF:"):
            found += int(line.split(":", 1)[1])
        elif line.startswith("LH:"):
            hit += int(line.split(":", 1)[1])
    return found, hit

def is_shared_source(source):
    if source.startswith("package:ssrvpn_shared/"):
        relative = source.removeprefix("package:ssrvpn_shared/")
        return relative == "ssrvpn_shared.dart" or relative.split("/", 1)[0] in {
            "controllers",
            "desktop_ui",
            "models",
            "services",
            "utils",
            "widgets",
        }
    return "/packages/ssrvpn_shared/lib/" in source

def read_dart_vm_coverage(directory):
    covered_lines = {}
    for path in directory.rglob("*.vm.json"):
        try:
            data = json.loads(path.read_text(errors="ignore"))
        except json.JSONDecodeError:
            print(f"coverage: warning invalid JSON {path}")
            continue
        for entry in data.get("coverage", []):
            source = entry.get("source", "")
            if not is_shared_source(source):
                continue
            hits = entry.get("hits") or []
            for index in range(0, len(hits), 2):
                key = (source, int(hits[index]))
                covered_lines[key] = max(
                    covered_lines.get(key, 0),
                    int(hits[index + 1]),
                )
    return len(covered_lines), sum(1 for count in covered_lines.values() if count > 0)

for target in targets:
    threshold = thresholds.get(target)
    if threshold is None:
        print(f"coverage: skip unknown target {target}")
        continue

    coverage_dir = Path(target) / "coverage"
    lcov = coverage_dir / "lcov.info"
    if lcov.exists():
        found, hit = read_lcov(lcov)
    elif target == "packages/ssrvpn_shared" and coverage_dir.exists():
        found, hit = read_dart_vm_coverage(coverage_dir)
    else:
        print(f"coverage: fail {target}, missing coverage output")
        failed = True
        continue

    if found == 0:
        print(f"coverage: fail {target}, no executable lines")
        failed = True
        continue

    percent = hit / found * 100
    print(f"coverage: {target} {percent:.2f}% ({hit}/{found}), threshold {threshold:.2f}%")
    if percent + 1e-9 < threshold:
        failed = True

if failed:
    raise SystemExit("coverage threshold failed")
PY
