#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

python3 -m unittest \
  scripts/test_check_release_assets.py \
  scripts/test_free_desktop_distribution.py \
  scripts/test_generate_oss_release_manifest.py \
  scripts/test_generate_release_notes.py \
  scripts/test_generate_release_provenance.py \
  scripts/test_promote_oss_public_channel.py \
  scripts/test_release_tooling_entrypoint.py \
  scripts/test_reuse_github_release_assets.py \
  scripts/test_run_command_with_timeout.py \
  scripts/test_secret_scanning.py \
  scripts/test_validate_existing_release_retry.py \
  scripts/test_verify_release_transition.py \
  scripts/test_windows_installer_config.py \
  scripts/test_windows_proxy_shutdown_recovery.py \
  scripts/test_windows_runonce_proxy_recovery.py
