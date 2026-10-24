#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/check-flutter-version.sh"
exec python3 "$ROOT/scripts/desktop_build_guard.py" build --platform macos "$@"
