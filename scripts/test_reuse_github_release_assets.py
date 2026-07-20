from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "reuse-github-release-assets.sh"
NAMES = (
    "SSRVPN.apk",
    "SSRVPN.dmg",
    "SSRVPN_Setup.exe",
)
CERT = "ab" * 32
COMMIT = "c" * 40


class ReuseGithubReleaseAssetsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.assets = self.root / "release-assets"
        self.asset_ids = self.root / "release-asset-ids"
        self.artifacts = self.root / "artifacts"
        self.bin_dir = self.root / "bin"
        self.android_home = self.root / "android-sdk"
        for directory in (
            self.assets,
            self.asset_ids,
            self.artifacts / "android",
            self.artifacts / "macos",
            self.artifacts / "windows",
            self.bin_dir,
            self.android_home / "build-tools" / "35.0.0",
        ):
            directory.mkdir(parents=True, exist_ok=True)

        for name in NAMES:
            payload = f"canonical-{name}".encode()
            (self.assets / name).write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            (self.assets / f"{name}.sha256").write_text(
                f"{digest}  {name}\n", encoding="ascii"
            )
        (self.assets / "SSRVPN-release-provenance.json").write_text(
            json.dumps(
                {
                    "schema": 1,
                    "tag": "v3.2.0",
                    "commit": COMMIT,
                    "assets": {
                        name: hashlib.sha256((self.assets / name).read_bytes()).hexdigest()
                        for name in NAMES
                    },
                }
            ),
            encoding="utf-8",
        )

        gh = self.bin_dir / "gh"
        gh.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"$FAKE_GH_LOG"
if [ "$1" = api ]; then
  if [[ "$*" == *'--method DELETE'* ]]; then
    if [ "$FAKE_API_MODE" = delete-transient ]; then
      attempts=0
      if [ -f "$FAKE_DELETE_ATTEMPTS" ]; then attempts="$(cat "$FAKE_DELETE_ATTEMPTS")"; fi
      attempts=$((attempts + 1))
      printf '%s' "$attempts" >"$FAKE_DELETE_ATTEMPTS"
      if [ "$attempts" -lt 3 ]; then
        echo 'gh: Service Unavailable (HTTP 503)' >&2
        exit 1
      fi
    fi
    touch "$FAKE_DELETE_MARKER"
    exit 0
  fi
  if [[ "$*" == *'/releases/assets/'* ]]; then
    attempts=0
    if [ -f "$FAKE_ASSET_ATTEMPTS" ]; then attempts="$(cat "$FAKE_ASSET_ATTEMPTS")"; fi
    attempts=$((attempts + 1))
    printf '%s' "$attempts" >"$FAKE_ASSET_ATTEMPTS"
    if [ "$FAKE_API_MODE" = asset-transient ] && [ "$attempts" -lt 3 ]; then
      echo 'gh: Service Unavailable (HTTP 503)' >&2
      exit 1
    fi
    endpoint="${!#}"
    cat "$FAKE_RELEASE_ASSET_IDS/${endpoint##*/}"
    exit 0
  fi
  case "$FAKE_API_MODE" in
    found | asset-transient | delete-transient) cat "$FAKE_RELEASE_JSON" ;;
    transient-found)
      attempts=0
      if [ -f "$FAKE_API_ATTEMPTS" ]; then attempts="$(cat "$FAKE_API_ATTEMPTS")"; fi
      attempts=$((attempts + 1))
      printf '%s' "$attempts" >"$FAKE_API_ATTEMPTS"
      if [ "$attempts" -lt 3 ]; then
        echo 'gh: Service Unavailable (HTTP 503)' >&2
        exit 1
      fi
      cat "$FAKE_RELEASE_JSON"
      ;;
    hidden-draft)
      if [[ "$*" == *'/releases/tags/'* ]]; then
        echo 'gh: Not Found (HTTP 404)' >&2
        exit 1
      fi
      printf '[['
      cat "$FAKE_RELEASE_JSON"
      printf ']]\\n'
      ;;
    duplicate-drafts)
      if [[ "$*" == *'/releases/tags/'* ]]; then
        echo 'gh: Not Found (HTTP 404)' >&2
        exit 1
      fi
      printf '[['
      cat "$FAKE_RELEASE_JSON"
      printf ','
      cat "$FAKE_RELEASE_JSON"
      printf ']]\\n'
      ;;
    missing)
      if [[ "$*" == *'/releases/tags/'* ]]; then
        echo 'gh: Not Found (HTTP 404)' >&2
        exit 1
      fi
      echo '[[]]'
      ;;
    *) echo 'gh: connection reset' >&2; exit 1 ;;
  esac
else
  echo "unexpected gh command: $*" >&2
  exit 2
fi
""",
            encoding="utf-8",
        )
        gh.chmod(0o755)

        apksigner = self.android_home / "build-tools" / "35.0.0" / "apksigner"
        apksigner.write_text(
            f"#!/usr/bin/env bash\necho 'Signer #1 certificate SHA-256 digest: {CERT}'\n",
            encoding="utf-8",
        )
        apksigner.chmod(0o755)

        self.release_json = self.root / "release.json"
        self.output = self.root / "output"
        self.delete_marker = self.root / "deleted"
        self.gh_log = self.root / "gh.log"
        self.api_attempts = self.root / "api-attempts"
        self.asset_attempts = self.root / "asset-attempts"
        self.delete_attempts = self.root / "delete-attempts"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _write_release(
        self,
        *,
        draft: bool,
        prerelease: bool = False,
        missing: str | None = None,
    ) -> None:
        assets = []
        for path in sorted(self.assets.iterdir()):
            if path.name == missing:
                continue
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            asset_id = len(assets) + 100
            (self.asset_ids / str(asset_id)).write_bytes(path.read_bytes())
            assets.append(
                {
                    "id": asset_id,
                    "name": path.name,
                    "size": path.stat().st_size,
                    "digest": f"sha256:{digest}",
                    "state": "uploaded",
                }
            )
        self.release_json.write_text(
            json.dumps(
                {
                    "id": 42,
                    "tag_name": "v3.2.0",
                    "draft": draft,
                    "prerelease": prerelease,
                    "assets": assets,
                }
            ),
            encoding="utf-8",
        )

    def _run(self, mode: str) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "FAKE_API_MODE": mode,
                "FAKE_RELEASE_JSON": str(self.release_json),
                "FAKE_RELEASE_ASSET_IDS": str(self.asset_ids),
                "FAKE_DELETE_MARKER": str(self.delete_marker),
                "FAKE_GH_LOG": str(self.gh_log),
                "FAKE_API_ATTEMPTS": str(self.api_attempts),
                "FAKE_ASSET_ATTEMPTS": str(self.asset_attempts),
                "FAKE_DELETE_ATTEMPTS": str(self.delete_attempts),
                "GITHUB_API_RETRY_BASE_SECONDS": "0",
                "GITHUB_REF_NAME": "v3.2.0",
                "GITHUB_SHA": COMMIT,
                "GITHUB_REPOSITORY": "Elegying/SSRVPN",
                "GITHUB_OUTPUT": str(self.output),
                "ANDROID_HOME": str(self.android_home),
                "ANDROID_RELEASE_CERT_SHA256": CERT,
            }
        )
        return subprocess.run(
            ["bash", str(SCRIPT), str(self.artifacts)],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )

    def test_missing_release_starts_a_fresh_draft(self) -> None:
        result = self._run("missing")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(), "exists=false\n")

    def test_complete_draft_reuses_verified_canonical_assets(self) -> None:
        self._write_release(draft=True)
        result = self._run("found")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("exists=true", self.output.read_text())
        self.assertIn("draft=true", self.output.read_text())
        self.assertIn("prerelease=false", self.output.read_text())
        for name, platform in (
            ("SSRVPN.apk", "android"),
            ("SSRVPN.dmg", "macos"),
            ("SSRVPN_Setup.exe", "windows"),
        ):
            self.assertEqual(
                (self.artifacts / platform / name).read_bytes(),
                (self.assets / name).read_bytes(),
            )

    def test_hidden_complete_draft_downloads_assets_by_validated_asset_id(self) -> None:
        self._write_release(draft=True)

        result = self._run("hidden-draft")

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.gh_log.read_text(encoding="utf-8")
        self.assertNotIn("release download", calls)
        self.assertEqual(calls.count("/releases/assets/"), 7)
        self.assertIn("exists=true", self.output.read_text(encoding="utf-8"))

    def test_partial_draft_is_deleted_without_deleting_the_tag(self) -> None:
        self._write_release(draft=True, missing="SSRVPN.dmg")
        result = self._run("found")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.delete_marker.is_file())
        self.assertEqual(self.output.read_text(), "exists=false\n")

    def test_hidden_partial_draft_is_discovered_and_deleted_by_release_id(self) -> None:
        self._write_release(draft=True, missing="SSRVPN.dmg")

        result = self._run("hidden-draft")

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.gh_log.read_text(encoding="utf-8")
        self.assertIn("repos/Elegying/SSRVPN/releases?per_page=100", calls)
        self.assertIn(
            "--method DELETE repos/Elegying/SSRVPN/releases/42",
            calls,
        )
        self.assertNotIn("release delete", calls)
        self.assertEqual(self.output.read_text(), "exists=false\n")

    def test_ambiguous_hidden_drafts_fail_closed(self) -> None:
        self._write_release(draft=True, missing="SSRVPN.dmg")

        result = self._run("duplicate-drafts")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Multiple GitHub releases", result.stderr)
        self.assertFalse(self.delete_marker.exists())

    def test_partial_draft_delete_retries_transient_api_failure(self) -> None:
        self._write_release(draft=True, missing="SSRVPN.dmg")

        result = self._run("delete-transient")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.delete_attempts.read_text(encoding="ascii"), "3")
        self.assertTrue(self.delete_marker.is_file())

    def test_draft_with_an_unfinished_upload_is_deleted_for_retry(self) -> None:
        self._write_release(draft=True)
        release = json.loads(self.release_json.read_text(encoding="utf-8"))
        release["assets"][0]["state"] = "starter"
        release["assets"][0]["digest"] = None
        self.release_json.write_text(json.dumps(release), encoding="utf-8")

        result = self._run("found")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.delete_marker.is_file())
        self.assertEqual(self.output.read_text(), "exists=false\n")

    def test_draft_with_retired_asset_is_recreated(self) -> None:
        (self.assets / "SSRVPN.zip").write_bytes(b"retired")
        self._write_release(draft=True)

        result = self._run("found")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.delete_marker.is_file())
        self.assertEqual(self.output.read_text(), "exists=false\n")

    def test_partial_public_release_fails_closed(self) -> None:
        self._write_release(draft=False, missing="SSRVPN.dmg")
        result = self._run("found")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to replace", result.stderr)
        self.assertFalse(self.delete_marker.exists())

    def test_api_network_failure_is_not_treated_as_absent(self) -> None:
        result = self._run("network")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unable to inspect", result.stderr)
        calls = self.gh_log.read_text(encoding="utf-8")
        self.assertEqual(calls.count("/releases/tags/v3.2.0"), 4)

    def test_transient_github_api_failure_is_retried_with_a_bound(self) -> None:
        self._write_release(draft=False)

        result = self._run("transient-found")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.api_attempts.read_text(encoding="ascii"), "3")
        self.assertIn("exists=true", self.output.read_text(encoding="utf-8"))

    def test_transient_asset_download_failure_is_retried(self) -> None:
        self._write_release(draft=True)

        result = self._run("asset-transient")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.asset_attempts.read_text(encoding="ascii"), "9")
        self.assertIn("exists=true", self.output.read_text(encoding="utf-8"))

    def test_prerelease_is_never_reused_or_promoted(self) -> None:
        self._write_release(draft=False, prerelease=True)

        result = self._run("found")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is a prerelease", result.stderr)
        self.assertFalse(self.delete_marker.exists())
        self.assertFalse(self.output.exists())

    def test_draft_prerelease_is_never_reused_or_deleted(self) -> None:
        self._write_release(draft=True, prerelease=True)

        result = self._run("found")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is a prerelease", result.stderr)
        self.assertFalse(self.delete_marker.exists())
        self.assertFalse(self.output.exists())

    def test_provenance_must_match_the_exact_tag_commit_and_assets(self) -> None:
        self._write_release(draft=True)
        provenance = json.loads(
            (self.assets / "SSRVPN-release-provenance.json").read_text(
                encoding="utf-8"
            )
        )
        provenance["commit"] = "d" * 40
        (self.assets / "SSRVPN-release-provenance.json").write_text(
            json.dumps(provenance), encoding="utf-8"
        )
        self._write_release(draft=True)

        result = self._run("found")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("provenance does not match", result.stderr)
        self.assertFalse(self.output.exists())

    def test_oversized_release_asset_is_rejected_before_download(self) -> None:
        self._write_release(draft=True)
        release = json.loads(self.release_json.read_text(encoding="utf-8"))
        next(asset for asset in release["assets"] if asset["name"] == "SSRVPN.apk")[
            "size"
        ] = 10**12
        self.release_json.write_text(json.dumps(release), encoding="utf-8")

        result = self._run("found")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("oversized asset", result.stderr)
        self.assertFalse(self.delete_marker.exists())

    def test_complete_release_with_invalid_asset_id_fails_closed(self) -> None:
        self._write_release(draft=True)
        release = json.loads(self.release_json.read_text(encoding="utf-8"))
        release["assets"][0]["id"] = None
        self.release_json.write_text(json.dumps(release), encoding="utf-8")

        result = self._run("found")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid asset metadata", result.stderr)
        self.assertFalse(self.asset_attempts.exists())


if __name__ == "__main__":
    unittest.main()
