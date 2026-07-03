#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

constant_version="$(
  awk -F"'" '/appVersion = / { print $2; exit }' \
    packages/ssrvpn_shared/lib/constants/app_constants.dart
)"

if [ -z "$constant_version" ]; then
  echo "version check failed: AppConstants.appVersion not found" >&2
  exit 1
fi

for pubspec in \
  SSRVPN_Android/pubspec.yaml \
  SSRVPN_MacOS/pubspec.yaml \
  SSRVPN_Windows/pubspec.yaml
do
  pubspec_version="$(
    awk '/^version:/ { print $2; exit }' "$pubspec" |
      tr -d '\r' |
      cut -d+ -f1
  )"
  if [ "$pubspec_version" != "$constant_version" ]; then
    echo "version check failed: $pubspec is $pubspec_version, AppConstants is $constant_version" >&2
    exit 1
  fi
done

echo "Version sync check passed: $constant_version"
