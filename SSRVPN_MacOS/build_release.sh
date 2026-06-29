#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
exec bash tool/package_macos.sh "$@"
