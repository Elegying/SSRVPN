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

workspace_version=""
for pubspec in \
  SSRVPN_Android/pubspec.yaml \
  SSRVPN_MacOS/pubspec.yaml \
  SSRVPN_Windows/pubspec.yaml
do
  full_version="$(
    awk '/^version:/ { print $2; exit }' "$pubspec" |
      tr -d '\r'
  )"
  if [ -z "$full_version" ]; then
    echo "version check failed: $pubspec has no version" >&2
    exit 1
  fi
  if [[ "$full_version" != *+* ]] ||
     ! [[ "${full_version##*+}" =~ ^[0-9]+$ ]] ||
     [ "${full_version##*+}" -le 0 ]; then
    echo "version check failed: $pubspec must include a positive numeric build code" >&2
    exit 1
  fi
  if [ -z "$workspace_version" ]; then
    workspace_version="$full_version"
  elif [ "$full_version" != "$workspace_version" ]; then
    echo "version check failed: $pubspec is $full_version, expected $workspace_version" >&2
    exit 1
  fi
done

base_version="${workspace_version%%+*}"
if [ "$base_version" != "$constant_version" ]; then
  echo "version check failed: pubspecs are $workspace_version, AppConstants is $constant_version" >&2
  exit 1
fi

version_pattern="${base_version//./\\.}"
if ! grep -Eq "^## \\[$version_pattern\\]( - [0-9]{4}-[0-9]{2}-[0-9]{2})?$" CHANGELOG.md; then
  echo "version check failed: CHANGELOG.md has no [$base_version] section" >&2
  exit 1
fi

health_version="$(
  awk -F '\140' '/^当前应用版本：/ { version=$2; sub(/^v/, "", version); print version; exit }' \
    docs/PROJECT_HEALTH.md
)"
if [ "$health_version" != "$base_version" ]; then
  echo "version check failed: docs/PROJECT_HEALTH.md is v${health_version:-unknown}, expected v$base_version" >&2
  exit 1
fi

echo "Version sync check passed: $workspace_version"
