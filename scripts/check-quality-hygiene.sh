#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v dart >/dev/null 2>&1; then
  echo "quality hygiene check failed: dart is not installed" >&2
  exit 1
fi
if ! command -v shellcheck >/dev/null 2>&1; then
  echo "quality hygiene check failed: shellcheck is not installed" >&2
  exit 1
fi
if [[ ! -f ".dart_tool/package_config.json" ]]; then
  if ! command -v flutter >/dev/null 2>&1; then
    echo "quality hygiene check failed: flutter is required to resolve the workspace" >&2
    exit 1
  fi
  flutter pub get --enforce-lockfile
fi

git ls-files -z -- '*.dart' |
  xargs -0 -n 100 dart format --output=none --set-exit-if-changed
git ls-files -z -- '*.sh' | xargs -0 -n 100 shellcheck

echo "Dart formatting and ShellCheck guards passed."
