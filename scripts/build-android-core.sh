#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-}"
SOURCE_REPO="https://github.com/zeyugao/mihomo.git"
SOURCE_COMMIT="7031b7569831677a8d89ad8a8a3347db116ba1a8"
SOURCE_TREE="023ddee8f965c54a263a16df68580585aa12c0f8"
GO_VERSION="go1.25.11"
MOBILE_VERSION="v0.0.0-20260602190626-68735029466e"
NDK_VERSION="28.2.13676358"

fail() {
  echo "Android core build failed: $*" >&2
  exit 1
}

test -n "$OUTPUT" || fail "usage: scripts/build-android-core.sh OUTPUT_SO"
case "$OUTPUT" in
  /*) ;;
  *) OUTPUT="$ROOT/$OUTPUT" ;;
esac

GO_BIN="${GO_BIN:-$(command -v go || true)}"
test -x "$GO_BIN" || fail "Go $GO_VERSION is required; set GO_BIN to its go executable"
test "$($GO_BIN version | awk '{print $3}')" = "$GO_VERSION" ||
  fail "Go $GO_VERSION is required, got $($GO_BIN version)"
GO_MODULE_CACHE="${GOMODCACHE:-$("$GO_BIN" env GOMODCACHE)}"
GO_BUILD_CACHE="${GOCACHE:-$("$GO_BIN" env GOCACHE)}"
test -n "$GO_MODULE_CACHE" || fail "Go module cache path is unavailable"
test -n "$GO_BUILD_CACHE" || fail "Go build cache path is unavailable"

ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
test -n "$ANDROID_SDK_ROOT" || fail "ANDROID_SDK_ROOT or ANDROID_HOME is required"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_SDK_ROOT/ndk/$NDK_VERSION}"
test -d "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" ||
  fail "Android NDK $NDK_VERSION is required at $ANDROID_NDK_HOME"

if test -z "${JAVA_HOME:-}"; then
  for candidate in \
    /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
    "/Applications/Android Studio.app/Contents/jbr/Contents/Home"; do
    if test -x "$candidate/bin/javac"; then
      JAVA_HOME="$candidate"
      break
    fi
  done
fi
test -x "${JAVA_HOME:-}/bin/javac" || fail "a JDK with javac is required; set JAVA_HOME"

for command in git unzip python3; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ssrvpn-android-core.XXXXXX")"
cleanup() {
  local exit_code=$?
  trap - EXIT
  chmod -R u+w "$BUILD_ROOT" 2>/dev/null || true
  rm -rf "$BUILD_ROOT"
  exit "$exit_code"
}
trap cleanup EXIT

SOURCE_DIR="$BUILD_ROOT/mihomo"
GOPATH_DIR="$BUILD_ROOT/gopath"
GOBIN_DIR="$GOPATH_DIR/bin"
mkdir -p "$GOBIN_DIR"

git clone --quiet --filter=blob:none --no-checkout "$SOURCE_REPO" "$SOURCE_DIR"
git -C "$SOURCE_DIR" checkout --quiet "$SOURCE_COMMIT"
test "$(git -C "$SOURCE_DIR" rev-parse HEAD)" = "$SOURCE_COMMIT" ||
  fail "Mihomo source commit mismatch"
test "$(git -C "$SOURCE_DIR" rev-parse 'HEAD^{tree}')" = "$SOURCE_TREE" ||
  fail "Mihomo source tree mismatch"

mkdir -p "$SOURCE_DIR/bridge"
cp "$ROOT/SSRVPN_Android/native/bridge/bridge.go" "$SOURCE_DIR/bridge/bridge.go"
cp "$ROOT/SSRVPN_Android/native/bridge/bridge_test.go" "$SOURCE_DIR/bridge/bridge_test.go"

export GOTOOLCHAIN=local
export GOPATH="$GOPATH_DIR"
export GOBIN="$GOBIN_DIR"
export GOMODCACHE="$GO_MODULE_CACHE"
export GOCACHE="$GO_BUILD_CACHE"
PATH="$(dirname "$GO_BIN"):$GOBIN_DIR:$JAVA_HOME/bin:$PATH"
export PATH
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export ANDROID_NDK_HOME
export NDK_HOME="$ANDROID_NDK_HOME"

"$GO_BIN" install "golang.org/x/mobile/cmd/gomobile@$MOBILE_VERSION"
"$GO_BIN" install "golang.org/x/mobile/cmd/gobind@$MOBILE_VERSION"

cd "$SOURCE_DIR"
"$GO_BIN" get -tool "golang.org/x/mobile/cmd/gobind@$MOBILE_VERSION"
GOFLAGS=-trimpath "$GO_BIN" test -tags=with_gvisor,cmfa ./bridge
GOFLAGS=-trimpath gomobile bind \
  -target=android/arm64 \
  -androidapi=24 \
  -tags=with_gvisor,cmfa \
  -o "$BUILD_ROOT/libgojni.aar" \
  ./bridge

unzip -q "$BUILD_ROOT/libgojni.aar" -d "$BUILD_ROOT/aar"
CANDIDATE="$BUILD_ROOT/aar/jni/arm64-v8a/libgojni.so"
python3 "$ROOT/scripts/verify_android_core_elf.py" "$CANDIDATE"

mkdir -p "$(dirname "$OUTPUT")"
install -m 0644 "$CANDIDATE" "$OUTPUT"
echo "built Android core: $OUTPUT"
