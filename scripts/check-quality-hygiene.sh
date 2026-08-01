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

git ls-files -z -- '*.dart' |
  xargs -0 dart format --output=none --set-exit-if-changed
git ls-files -z -- '*.sh' | xargs -0 shellcheck

echo "Dart formatting and ShellCheck guards passed."
