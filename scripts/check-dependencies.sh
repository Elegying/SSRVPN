#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> Workspace dependency status"
flutter pub outdated --no-dev-dependencies

echo
echo "Dependency status check completed."
