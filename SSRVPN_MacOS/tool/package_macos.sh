#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SSRVPN"
APP_PATH="$PROJECT_ROOT/build/macos/Build/Products/Release/$APP_NAME.app"
VERSION_RAW="$(awk '/^version:/ {print $2; exit}' "$PROJECT_ROOT/pubspec.yaml" | tr -d '\r')"
VERSION_NAME="${VERSION_RAW%%+*}"
PACKAGE_DIR="$PROJECT_ROOT/build/package_macos"
STAGING_DIR="$PACKAGE_DIR/staging"
MOUNT_DIR="$PACKAGE_DIR/mount"
RW_DMG_PATH="$PACKAGE_DIR/${APP_NAME}-rw.dmg"
ARCH="$(uname -m)"
VERSIONED_DMG_PATH="$PROJECT_ROOT/${APP_NAME}-macOS-${ARCH}-v${VERSION_NAME}.dmg"
DMG_PATH="$PROJECT_ROOT/${APP_NAME}.dmg"
DMG_HASH_PATH="$PROJECT_ROOT/${APP_NAME}.dmg.sha256"
CORE_TMP=""

cleanup() {
  if [[ -d "$MOUNT_DIR" ]] && mount | grep -qF "$MOUNT_DIR"; then
    hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
  fi
  rm -f "$CORE_TMP"
  rm -rf "$MOUNT_DIR"
}
trap cleanup EXIT

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
gzip -cd "$ASSET_DIR/AtlasCore.gz" > "$CORE_TMP"
file "$CORE_TMP"

rm -rf "$STAGING_DIR" "$MOUNT_DIR"
rm -f "$VERSIONED_DMG_PATH" "$DMG_PATH" "$DMG_HASH_PATH" "$RW_DMG_PATH"
mkdir -p "$STAGING_DIR"

ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
test -L "$STAGING_DIR/Applications"

cat > "$STAGING_DIR/INSTALL.txt" <<'EOF'
Install SSRVPN:
1. Drag SSRVPN.app to Applications.
2. Open SSRVPN from Applications.

If macOS blocks the app, right-click SSRVPN.app and choose Open.
EOF

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -fs HFS+ \
  -format UDRW \
  "$RW_DMG_PATH"

mkdir -p "$MOUNT_DIR"
hdiutil attach "$RW_DMG_PATH" -mountpoint "$MOUNT_DIR"

echo "Applying drag-to-Applications Finder layout..."
command -v osascript >/dev/null
osascript <<EOF
set dmgFolder to POSIX file "$MOUNT_DIR" as alias
tell application "Finder"
  open dmgFolder
  set dmgWindow to container window of dmgFolder
  set current view of dmgWindow to icon view
  set toolbar visible of dmgWindow to false
  set statusbar visible of dmgWindow to false
  set the bounds of dmgWindow to {100, 100, 640, 420}
  set arrangement of icon view options of dmgWindow to not arranged
  set icon size of icon view options of dmgWindow to 96
  set position of item "$APP_NAME.app" of dmgFolder to {160, 180}
  set position of item "Applications" of dmgFolder to {420, 180}
  set position of item "INSTALL.txt" of dmgFolder to {290, 310}
  update dmgFolder without registering applications
  delay 2
  close dmgWindow
end tell
EOF

sync
for attempt in 1 2 3; do
  if hdiutil detach "$MOUNT_DIR"; then
    break
  fi
  sleep 2
  if [[ "$attempt" -eq 3 ]]; then
    hdiutil detach "$MOUNT_DIR" -force
  fi
done
rm -rf "$MOUNT_DIR"

hdiutil convert "$RW_DMG_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$VERSIONED_DMG_PATH"

hdiutil verify "$VERSIONED_DMG_PATH"
ditto "$VERSIONED_DMG_PATH" "$DMG_PATH"

echo "DMG: $DMG_PATH"
SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
printf '%s  %s\n' "$SHA256" "$(basename "$DMG_PATH")" > "$DMG_HASH_PATH"
echo "Versioned DMG: $VERSIONED_DMG_PATH"
echo "SHA256: $SHA256"
