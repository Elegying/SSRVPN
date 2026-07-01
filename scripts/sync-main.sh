#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ -n "$(git status --porcelain)" ]; then
  echo "Cannot sync: the working tree has local changes."
  echo "Run 'make status' to inspect them, then commit/stash/archive first."
  exit 1
fi

current="$(git branch --show-current)"
if [ "$current" != "main" ]; then
  git switch main
fi

git fetch origin --prune --tags
git pull --ff-only origin main

echo "main is up to date with origin/main."
