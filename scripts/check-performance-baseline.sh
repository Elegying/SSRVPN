#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/packages/ssrvpn_shared"

dart run tool/benchmark_critical_paths.dart --smoke --verify
