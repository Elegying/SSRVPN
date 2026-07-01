#!/usr/bin/env bash
set -euo pipefail

if [ $# -lt 1 ] || [ -z "${1// }" ]; then
  echo "Usage: scripts/start-feature.sh short-feature-name"
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

raw="$1"
slug="$(printf '%s' "$raw" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')"

if [ -z "$slug" ]; then
  echo "Feature name did not contain usable characters."
  exit 1
fi

scripts/sync-main.sh

branch="feature/$slug"
if git show-ref --verify --quiet "refs/heads/$branch"; then
  echo "Branch already exists locally: $branch"
  git switch "$branch"
else
  git switch -c "$branch"
fi

echo "Ready for work on $branch."
