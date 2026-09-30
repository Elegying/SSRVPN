#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
bash scripts/check-flutter-version.sh

# Focused behavior gate; CI's full package suites discover these tests too.
(cd packages/ssrvpn_shared && flutter test \
  test/connection_fault_sequence_test.dart \
  test/clash_service_base_test.dart \
  test/connection_phase_trace_test.dart test/app_diagnostics_test.dart \
  test/proxy_egress_policy_test.dart \
  test/subscription_uri_compatibility_test.dart)
for app in SSRVPN_Android SSRVPN_MacOS SSRVPN_Windows; do
  (cd "$app" && flutter test test/runtime_compatibility_test.dart)
done
(cd SSRVPN_Windows && flutter test \
  test/core_process_termination_test.dart test/tun_runtime_health_test.dart \
  test/clash_service_lifecycle_test.dart \
  test/unexpected_core_exit_recovery_test.dart)
