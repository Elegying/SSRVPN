#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "SKIP: macOS native XCTest requires a Darwin host."
  exit 0
fi

for command in flutter python3 xcodebuild; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "macOS native tests require $command." >&2
    exit 1
  fi
done

REPORTS_DIR="${SSRVPN_DIAGNOSTIC_REPORTS_DIR:-${HOME}/Library/Logs/DiagnosticReports}"
SETTLE_SECONDS="${SSRVPN_CRASH_REPORT_SETTLE_SECONDS:-8}"
TEMPORARY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/ssrvpn-macos-native.XXXXXX")"
BASELINE="$TEMPORARY_DIRECTORY/crash-reports.json"
PROCESS_BASELINE="$TEMPORARY_DIRECTORY/processes.txt"
DERIVED_DATA="$TEMPORARY_DIRECTORY/DerivedData"
cleanup_temporary_directory=0
# Invoked by the EXIT trap below.
# shellcheck disable=SC2329
cleanup() {
  local exit_status=$?
  trap - EXIT
  if (( cleanup_temporary_directory == 1 )); then
    /bin/rm -rf "$TEMPORARY_DIRECTORY"
    if [[ -e "$TEMPORARY_DIRECTORY" ]]; then
      echo "Could not remove macOS native test temporary data: $TEMPORARY_DIRECTORY" >&2
      if (( exit_status == 0 )); then exit_status=1; fi
    fi
  else
    echo "Preserved macOS native test diagnostics: $TEMPORARY_DIRECTORY" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT

snapshot_arguments=(
  snapshot
  --reports-dir "$REPORTS_DIR"
  --output "$BASELINE"
  --process-output "$PROCESS_BASELINE"
)
if [[ -n "${SSRVPN_MACOS_PROCESS_LIST_FILE:-}" ]]; then
  if [[ "${SSRVPN_MACOS_GATE_TESTING:-}" != "1" ]]; then
    echo "SSRVPN_MACOS_PROCESS_LIST_FILE is test-only." >&2
    exit 1
  fi
  snapshot_arguments+=(
    --process-list-file "$SSRVPN_MACOS_PROCESS_LIST_FILE"
  )
fi

(
  cd "$ROOT/SSRVPN_MacOS"
  flutter build macos --debug --config-only --no-pub
)

python3 "$ROOT/scripts/macos_native_post_test_gate.py" \
  "${snapshot_arguments[@]}"

xcodebuild_status=0
(
  cd "$ROOT/SSRVPN_MacOS"
  xcodebuild test \
    -quiet \
    -workspace macos/Runner.xcworkspace \
    -scheme Runner \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -only-testing:RunnerTests \
    -parallel-testing-enabled NO \
    -maximum-parallel-testing-workers 1 \
    CODE_SIGNING_ALLOWED=NO
) || xcodebuild_status=$?

post_test_arguments=(
  check
  --reports-dir "$REPORTS_DIR"
  --baseline "$BASELINE"
  --wait-seconds "$SETTLE_SECONDS"
  --derived-data-path "$DERIVED_DATA"
  --process-baseline "$PROCESS_BASELINE"
)
if [[ -n "${SSRVPN_MACOS_PROCESS_LIST_FILE:-}" ]]; then
  post_test_arguments+=(
    --process-list-file "$SSRVPN_MACOS_PROCESS_LIST_FILE"
  )
fi

post_test_status=0
python3 "$ROOT/scripts/macos_native_post_test_gate.py" \
  "${post_test_arguments[@]}" || post_test_status=$?

final_status=$post_test_status
if (( xcodebuild_status != 0 )); then
  final_status=$xcodebuild_status
fi
if (( final_status == 0 )); then
  cleanup_temporary_directory=1
fi
exit "$final_status"
