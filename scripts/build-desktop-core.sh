#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${1:-}"
OUTPUT="${2:-}"
[[ "$PLATFORM" == macos || "$PLATFORM" == windows ]] && [[ -n "$OUTPUT" ]] || {
  echo "usage: scripts/build-desktop-core.sh macos|windows OUTPUT_BINARY" >&2
  exit 1
}
[[ "$OUTPUT" == /* ]] || OUTPUT="$ROOT/$OUTPUT"
IFS=$'\t' read -r SOURCE_REPO SOURCE_COMMIT GO_VERSION VERSION < <(
  python3 - "$ROOT/native/proxy_traffic/sources.json" "$PLATFORM" <<'PY'
import json, sys
source = json.load(open(sys.argv[1]))[sys.argv[2]]
print('\t'.join(source[key] for key in ('repository', 'commit', 'go', 'version')))
PY
)
GO_BIN="${GO_BIN:-$(command -v go)}"
[[ "$($GO_BIN version | awk '{print $3}')" == "$GO_VERSION" ]] || {
  echo "Expected $GO_VERSION; set GO_BIN to that pinned toolchain." >&2
  exit 1
}
GOROOT="$(cd "$(dirname "$GO_BIN")/.." && pwd)"
export GOROOT
export GOTOOLCHAIN=local
export GOMAXPROCS=2
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ssrvpn-desktop-core.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT
git clone --quiet --filter=blob:none --no-checkout "$SOURCE_REPO" "$BUILD_ROOT/core"
git -C "$BUILD_ROOT/core" checkout --quiet "$SOURCE_COMMIT"
python3 "$ROOT/scripts/core-traffic-source.py" apply "$PLATFORM" "$BUILD_ROOT/core"
cd "$BUILD_ROOT/core"
"$GO_BIN" test -p 2 -tags=with_gvisor ./tunnel/statistic ./adapter/outbound ./hub/route
TARGET_OS=darwin
TARGET_ARCH=arm64
if [[ "$PLATFORM" == windows ]]; then
  TARGET_OS=windows
  TARGET_ARCH=amd64
fi
mkdir -p "$(dirname "$OUTPUT")"
CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$TARGET_ARCH" GOAMD64=v1 \
  "$GO_BIN" build -p 2 -trimpath -tags=with_gvisor \
  -ldflags="-s -w -X github.com/metacubex/mihomo/constant.Version=$VERSION-ssrvpn.1 -X github.com/metacubex/mihomo/constant.BuildTime=2026-09-06" \
  -o "$OUTPUT" .
echo "Built $PLATFORM proxy-traffic core: $OUTPUT"
