#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_BIN="${SSRVPN_FLUTTER_BIN:-flutter}"

expected="$(python3 - "$ROOT/.fvmrc" <<'PY'
import json
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8")).get("flutter")
if not isinstance(value, str) or not value.strip():
    raise SystemExit(".fvmrc does not contain a non-empty flutter version")
print(value.strip())
PY
)"

if ! machine="$("$FLUTTER_BIN" --version --machine 2>/dev/null)"; then
  echo "Flutter toolchain check failed: cannot run '$FLUTTER_BIN --version --machine'." >&2
  echo "Install Flutter $expected with FVM or mise, then retry." >&2
  exit 1
fi

if ! actual="$(printf '%s' "$machine" | python3 -c '
import json
import sys

value = json.load(sys.stdin).get("frameworkVersion")
if not isinstance(value, str) or not value.strip():
    raise SystemExit(1)
print(value.strip())
')"; then
  echo "Flutter toolchain check failed: --version --machine returned invalid JSON." >&2
  exit 1
fi

if [[ "$actual" != "$expected" ]]; then
  echo "Flutter version mismatch: expected $expected from .fvmrc, got $actual." >&2
  echo "Run 'fvm install && fvm exec make verify' or 'mise exec flutter@$expected -- make verify'." >&2
  exit 1
fi

echo "Flutter toolchain version verified: $actual"
