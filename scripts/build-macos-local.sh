#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/check-flutter-version.sh"
cd "$ROOT/SSRVPN_MacOS"
# Account usage providers are compiled into the app, including acceptance builds.
flutter build macos --release \
  --dart-define-from-file="$ROOT/config/ssrvpn-usage-defines.json" "$@"
