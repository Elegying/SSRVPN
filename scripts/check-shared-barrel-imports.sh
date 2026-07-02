#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

matches="$(
  git grep -nE "^import 'package:ssrvpn_shared/(models|services|utils|constants)/" \
    -- SSRVPN_Android SSRVPN_MacOS SSRVPN_Windows || true
)"

if [[ -n "$matches" ]]; then
  echo "Direct ssrvpn_shared internal imports are not allowed."
  echo "Use package:ssrvpn_shared/ssrvpn_shared.dart instead."
  echo
  echo "$matches"
  exit 1
fi

echo "ssrvpn_shared barrel import check passed."
