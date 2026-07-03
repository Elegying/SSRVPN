#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

targets=("$@")
if [[ "${#targets[@]}" -eq 0 ]]; then
  targets=(SSRVPN_Android SSRVPN_MacOS SSRVPN_Windows)
fi

python3 - "$@" <<'PY'
from pathlib import Path
import sys

thresholds = {
    "SSRVPN_Android": 40.0,
    "SSRVPN_MacOS": 20.0,
    "SSRVPN_Windows": 20.0,
}

targets = sys.argv[1:] or list(thresholds)
failed = False

for target in targets:
    threshold = thresholds.get(target)
    if threshold is None:
        print(f"coverage: skip unknown target {target}")
        continue

    lcov = Path(target) / "coverage" / "lcov.info"
    if not lcov.exists():
        print(f"coverage: skip {target}, missing {lcov}")
        continue

    found = hit = 0
    for line in lcov.read_text(errors="ignore").splitlines():
        if line.startswith("LF:"):
            found += int(line.split(":", 1)[1])
        elif line.startswith("LH:"):
            hit += int(line.split(":", 1)[1])

    if found == 0:
        print(f"coverage: skip {target}, no executable lines")
        continue

    percent = hit / found * 100
    print(f"coverage: {target} {percent:.2f}% ({hit}/{found}), threshold {threshold:.2f}%")
    if percent + 1e-9 < threshold:
        failed = True

if failed:
    raise SystemExit("coverage threshold failed")
PY
