#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SKIP: macOS native XCTest requires a Darwin host."
  exit 0
fi

for command in flutter xcodebuild; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "macOS native tests require $command." >&2
    exit 1
  fi
done

(
  cd "$ROOT/SSRVPN_MacOS"
  flutter build macos --debug --config-only --no-pub
  xcodebuild test \
    -quiet \
    -workspace macos/Runner.xcworkspace \
    -scheme Runner \
    -configuration Debug \
    -destination 'platform=macOS' \
    -only-testing:RunnerTests \
    CODE_SIGNING_ALLOWED=NO
)
