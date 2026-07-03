#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

run_timed() {
  local title="$1"
  shift
  local start end elapsed
  start="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"
  "$@"
  end="$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)"
  elapsed=$((end - start))
  echo "perf: $title ${elapsed}ms"
}

echo "perf: source size hotspots"
git ls-files '*.dart' '*.kt' |
  xargs wc -l |
  sort -nr |
  awk 'NR <= 12 {print "perf: " $0}'

echo
run_timed "shared home controller tests" \
  bash -lc 'cd packages/ssrvpn_shared && dart test test/home_node_controller_test.dart >/dev/null'
run_timed "shared subscription parser tests" \
  bash -lc 'cd packages/ssrvpn_shared && dart test test/subscription_parser_test.dart >/dev/null'

echo
if command -v adb >/dev/null 2>&1; then
  device="$(adb devices | awk 'NR > 1 && $2 == "device" {print $1; exit}')"
  if [[ -n "$device" ]]; then
    echo "perf: adb device $device"
    if adb -s "$device" shell pm path com.ssrvpn.android >/dev/null 2>&1; then
      adb -s "$device" shell am force-stop com.ssrvpn.android >/dev/null 2>&1 || true
      adb -s "$device" shell am start -W com.ssrvpn.android/.MainActivity 2>/dev/null |
        sed 's/^/perf: android-start: /'
      adb -s "$device" shell dumpsys meminfo com.ssrvpn.android 2>/dev/null |
        awk '/TOTAL PSS:/ || /TOTAL RSS:/ || /TOTAL:/ {print "perf: android-mem: " $0; seen=1} seen && ++count >= 3 {exit}'
    else
      echo "perf: Android package com.ssrvpn.android is not installed; skip device startup sample"
    fi
  else
    echo "perf: no adb device; skip Android device sample"
  fi
else
  echo "perf: adb not found; skip Android device sample"
fi

echo
echo "perf: baseline complete; compare these numbers between releases before optimizing for low-end devices."
