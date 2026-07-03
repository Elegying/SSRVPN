#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/SSRVPN_Android/android/ssrvpn-release.jks}"
ALIAS="${ANDROID_KEY_ALIAS:-ssrvpn}"

if [ -e "$OUT" ]; then
  echo "Refusing to overwrite existing keystore: $OUT" >&2
  exit 1
fi

command -v keytool >/dev/null 2>&1 || {
  echo "keytool not found. Install a JDK first." >&2
  exit 1
}

mkdir -p "$(dirname "$OUT")"
keytool -genkeypair \
  -v \
  -keystore "$OUT" \
  -alias "$ALIAS" \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000

echo
echo "Keystore created: $OUT"
echo "Keep it private and backed up. Losing it means Android users cannot upgrade in place."
echo
echo "GitHub Actions secrets:"
echo "ANDROID_KEY_ALIAS=$ALIAS"
echo "ANDROID_KEYSTORE_BASE64=$(base64 < "$OUT" | tr -d '\n')"
echo "ANDROID_KEYSTORE_PASSWORD=<the keystore password you entered>"
echo "ANDROID_KEY_PASSWORD=<the key password you entered>"
