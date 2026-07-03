#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

python3 - <<'PY'
from pathlib import Path
import re
import subprocess
import sys

patterns = [
    ("private key", re.compile(r"-----BEGIN (RSA |EC |OPENSSH |DSA |)?PRIVATE KEY-----")),
    ("aws access key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("github token", re.compile(r"\bgh[pousr]_[A-Za-z0-9_]{36,}\b")),
    ("google api key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("slack token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b")),
]

skip_suffixes = {
    ".apk",
    ".dmg",
    ".exe",
    ".gz",
    ".ico",
    ".jar",
    ".jks",
    ".png",
    ".so",
    ".zip",
}

files = subprocess.check_output(["git", "ls-files"], text=True).splitlines()
matches = []
for name in files:
    path = Path(name)
    if path.suffix.lower() in skip_suffixes:
        continue
    try:
        text = path.read_text(errors="ignore")
    except Exception:
        continue
    for label, pattern in patterns:
        for match in pattern.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            matches.append(f"{name}:{line}: possible {label}")

if matches:
    print("\n".join(matches))
    sys.exit("secret scan failed")

print("secret scan passed.")
PY
