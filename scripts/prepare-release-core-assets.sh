#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
arguments=(--repo "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
  --sha "$(git rev-parse --verify 'HEAD^{commit}')")
if [ -n "${1:-}" ]; then
  arguments+=(--run-id "$1")
fi
status=0
python3 scripts/reuse-ci-core-assets.py "${arguments[@]}" || status=$?
case "$status" in
  0) ;;
  3)
    echo "Verified CI cores are unavailable or expired; rebuilding pinned cores."
    bash scripts/bootstrap-core-assets.sh
    ;;
  *) exit "$status" ;;
esac
bash scripts/verify-core-assets.sh
