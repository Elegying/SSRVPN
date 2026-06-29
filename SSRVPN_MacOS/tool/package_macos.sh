#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SSRVPN"
APP_PATH="$PROJECT_ROOT/build/macos/Build/Products/Release/$APP_NAME.app"
VERSION_RAW="$(awk '/^version:/ {print $2; exit}' "$PROJECT_ROOT/pubspec.yaml" | tr -d '\r')"
VERSION_NAME="${VERSION_RAW%%+*}"
STAGING_DIR="$PROJECT_ROOT/build/package_macos/staging"
ARCH="$(uname -m)"
VERSIONED_DMG_PATH="$PROJECT_ROOT/${APP_NAME}-macOS-${ARCH}-v${VERSION_NAME}.dmg"
DMG_PATH="$PROJECT_ROOT/${APP_NAME}.dmg"
DMG_HASH_PATH="$PROJECT_ROOT/${APP_NAME}.dmg.sha256"

cd "$PROJECT_ROOT"

echo "Building $APP_NAME $VERSION_RAW for macOS $ARCH..."
flutter build macos --release

if [[ ! -d "$APP_PATH" ]]; then
  echo "Release app not found: $APP_PATH" >&2
  exit 1
fi

APP_BIN="$APP_PATH/Contents/MacOS/$APP_NAME"
ASSET_DIR="$APP_PATH/Contents/Frameworks/App.framework/Resources/flutter_assets/assets"

test -x "$APP_BIN"
test -f "$ASSET_DIR/AtlasCore.gz"
test -f "$ASSET_DIR/geoip.metadb.gz"
test -f "$ASSET_DIR/tray_icon.png"

echo "Refreshing ad-hoc code signature..."
/usr/bin/codesign --force --deep --sign - "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "App binary:"
file "$APP_BIN"
lipo -info "$APP_BIN"

echo "Bundled core:"
CORE_TMP="$(mktemp)"
trap 'rm -f "$CORE_TMP"' EXIT
gzip -cd "$ASSET_DIR/AtlasCore.gz" > "$CORE_TMP"
file "$CORE_TMP"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
cat > "$STAGING_DIR/使用教程.txt" <<'EOF'
【使用教程】
拖拽软件到左边的 Applications文件夹里
然后去应用程序里找到 SSRVPN 这个软件打开使用

如果提示：无法打开"SSRVPN"，因为Apple无法检查其是否包含恶意软件。
就右键软件图标，选择【打开】
EOF

rm -f "$VERSIONED_DMG_PATH" "$DMG_PATH" "$DMG_HASH_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$VERSIONED_DMG_PATH"

hdiutil verify "$VERSIONED_DMG_PATH"
ditto "$VERSIONED_DMG_PATH" "$DMG_PATH"

echo "DMG: $DMG_PATH"
SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
printf '%s  %s\n' "$SHA256" "$(basename "$DMG_PATH")" > "$DMG_HASH_PATH"
echo "Versioned DMG: $VERSIONED_DMG_PATH"
echo "SHA256: $SHA256"
