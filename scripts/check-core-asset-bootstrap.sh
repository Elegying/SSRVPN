#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "core asset bootstrap guard failed: $*" >&2
  exit 1
}

if grep -n 'filter=lfs' .gitattributes >/dev/null; then
  fail "Git LFS is still required by the current tree"
fi

bootstrap="scripts/bootstrap-core-assets.sh"
test -x "$bootstrap" || fail "$bootstrap is missing or not executable"

assets=(
  SSRVPN_Android/android/app/src/main/jniLibs/arm64-v8a/libgojni.so
  SSRVPN_Android/assets/geoip.metadb.gz
  SSRVPN_MacOS/assets/AtlasCore.gz
  SSRVPN_MacOS/assets/geoip.metadb.gz
  SSRVPN_Windows/assets/mihomo.exe
  SSRVPN_Windows/assets/geoip.metadb.gz
)

for asset in "${assets[@]}"; do
  if git ls-files --error-unmatch "$asset" >/dev/null 2>&1; then
    fail "generated core asset is still tracked: $asset"
  fi
  git check-ignore -q "$asset" || fail "generated core asset is not ignored: $asset"
done

if grep -R -n -E 'lfs:[[:space:]]*true' .github/workflows >/dev/null; then
  fail "a GitHub Actions workflow still downloads Git LFS objects"
fi

for workflow in .github/workflows/ci.yml .github/workflows/release.yml; do
  grep -Fq 'scripts/bootstrap-core-assets.sh' "$workflow" ||
    fail "$workflow does not bootstrap verified core assets"
  grep -Fq 'scripts/check-core-asset-bootstrap.sh' "$workflow" ||
    fail "$workflow does not enforce the core asset bootstrap model"
done

echo "Core asset bootstrap guards passed."
