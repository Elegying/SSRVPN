#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

python3 - <<'PY'
from pathlib import Path
import re

settings = Path("SSRVPN_Android/android/settings.gradle.kts").read_text(encoding="utf-8")
app = Path("SSRVPN_Android/android/app/build.gradle.kts").read_text(encoding="utf-8")
properties = Path("SSRVPN_Android/android/gradle.properties").read_text(encoding="utf-8")
wrapper = Path(
    "SSRVPN_Android/android/gradle/wrapper/gradle-wrapper.properties"
).read_text(encoding="utf-8")
manifest = Path(
    "SSRVPN_Android/android/app/src/main/AndroidManifest.xml"
).read_text(encoding="utf-8")

if re.search(r'''id\(["'](?:kotlin-android|org\.jetbrains\.kotlin\.android)["']\)''', app):
    raise SystemExit("app/build.gradle.kts still applies the legacy Kotlin plugin")
if not re.search(r'''id\(["']com\.android\.application["']\) version ["']9\.''', settings):
    raise SystemExit("Android application plugin must use AGP 9.x")
if not re.search(
    r'''id\(["']com\.android\.built-in-kotlin["']\) version ["']9\.0\.1["'] apply false''',
    settings,
):
    raise SystemExit("settings.gradle.kts must declare the AGP 9 built-in Kotlin plugin")
if not re.search(r'''id\(["']com\.android\.built-in-kotlin["']\)''', app):
    raise SystemExit("the app module must explicitly opt into built-in Kotlin")
if "android.builtInKotlin=false" not in properties:
    raise SystemExit("unmigrated third-party plugins require the temporary global opt-out")
if "android.newDsl=false" not in properties:
    raise SystemExit("Flutter 3.44 still requires the temporary new-DSL opt-out")
for obsolete_property in ("android.enableJetifier", "android.overridePathCheck"):
    if obsolete_property in properties:
        raise SystemExit(f"obsolete Android property remains: {obsolete_property}")
if "gradle-9.1.0-bin.zip" not in wrapper:
    raise SystemExit("AGP 9.0.x requires the pinned Gradle 9.1.0 wrapper")
if "jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17" not in app:
    raise SystemExit("built-in Kotlin must target the AGP 9 JDK 17 baseline")
if "android:extractNativeLibs" in manifest:
    raise SystemExit("AGP 9 forbids extractNativeLibs in AndroidManifest.xml")
if "useLegacyPackaging = true" not in app:
    raise SystemExit("native core extraction must use the AGP 9 packaging DSL")

print("Android built-in Kotlin migration guard passed.")
PY
