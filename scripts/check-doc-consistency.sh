#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

current_docs=(
  README.md
  SECURITY.md
  CONTRIBUTING.md
  MIGRATION.md
  SSRVPN_Android/README.md
  SSRVPN_Android/USER_GUIDE.md
  SSRVPN_MacOS/README.md
  SSRVPN_MacOS/USER_GUIDE.md
  SSRVPN_Windows/README.md
  SSRVPN_Windows/USER_GUIDE.md
  docs/README.md
  docs/CORE_ASSETS.md
  docs/IPV6_DUAL_STACK_SPEC.zh-CN.md
  docs/MAINTENANCE.md
  docs/OSS_RELEASE_OPERATIONS.zh-CN.md
  docs/OWNER_GUIDE.zh-CN.md
  docs/PRODUCT_REQUIREMENTS.zh-CN.md
  docs/PROJECT_HEALTH.md
  docs/PROJECT_MANAGEMENT.md
  docs/RELEASE_CHECKLIST.zh-CN.md
  docs/RELEASE_SIGNING.md
  docs/ROADMAP.md
  docs/TESTING.md
  docs/TROUBLESHOOTING.zh-CN.md
  docs/UI_DESIGN_GUIDE.md
  docs/USER_GUIDE.zh-CN.md
  docs/decisions/001-desktop-api-secret-storage.md
)

python3 "$ROOT/scripts/check_doc_consistency.py" --self-test
python3 "$ROOT/scripts/check_doc_consistency.py" "$ROOT" "${current_docs[@]}"
