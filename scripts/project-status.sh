#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "SSRVPN project status"
echo "====================="
echo "Path:   $ROOT"
echo "Branch: $(git branch --show-current)"

upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
if [ -n "$upstream" ]; then
  git fetch -q --prune --tags origin || true
  counts="$(git rev-list --left-right --count "$upstream"...HEAD 2>/dev/null || echo "0 0")"
  behind="${counts%%	*}"
  ahead="${counts##*	}"
  echo "Remote: $upstream"
  echo "Sync:   behind $behind, ahead $ahead"
else
  echo "Remote: no upstream configured"
fi

echo
echo "Working tree"
echo "------------"
if [ -z "$(git status --porcelain)" ]; then
  echo "Clean"
else
  git status --short
fi

echo
echo "Local deliverables"
echo "------------------"
for file in dist/SSRVPN.apk dist/SSRVPN.dmg SSRVPN_Windows/SSRVPN_Setup.exe; do
  if [ -f "$file" ]; then
    size="$(du -h "$file" | awk '{print $1}')"
    echo "OK   $file ($size)"
  else
    echo "MISS $file"
  fi
done

echo
echo "Latest GitHub release"
echo "---------------------"
if command -v gh >/dev/null 2>&1; then
  gh release view --json tagName,url --jq '"\(.tagName)  \(.url)"' 2>/dev/null || echo "No release found or gh is not authenticated"
else
  echo "GitHub CLI not installed"
fi
