#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "usage: $0 <coverage-target>" >&2
  exit 2
fi
shift

coverage_args=(--coverage)
case "$TARGET" in
  packages/ssrvpn_shared | SSRVPN_Android)
    ;;
  SSRVPN_MacOS)
    coverage_args+=(--coverage-package='ssrvpn_.*')
    ;;
  SSRVPN_Windows)
    coverage_args+=(--coverage-package='ssrvpn_.*')
    ;;
  *)
    echo "coverage: unknown target $TARGET" >&2
    exit 2
    ;;
esac

(cd "$ROOT/$TARGET" && flutter test "${coverage_args[@]}" "$@")
