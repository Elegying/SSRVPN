from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/authorize-existing-release-retry.py"
COMMIT = "b" * 40
TAG = "v3.2.0"
REQUIRED_ASSETS = (
    "SSRVPN.apk",
    "SSRVPN.apk.sha256",
    "SSRVPN.dmg",
    "SSRVPN.dmg.sha256",
    "SSRVPN_Setup.exe",
    "SSRVPN_Setup.exe.sha256",
    "SSRVPN-release-provenance.json",
)


class AuthorizeExistingReleaseRetryTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.work_dir = self.root / "work"
        self.release_json = self.root / "release.json"
        self.provenance = self.root / "provenance.json"
        self.log = self.root / "gh.log"
        self.github_output = self.root / "github-output"

        provenance = {
            "schema": 1,
            "tag": TAG,
            "commit": COMMIT,
            "assets": {
                "SSRVPN.apk": "a" * 64,
                "SSRVPN.dmg": "a" * 64,
                "SSRVPN_Setup.exe": "a" * 64,
            },
        }
        provenance_bytes = json.dumps(provenance, sort_keys=True).encode("utf-8")
        self.provenance.write_bytes(provenance_bytes)

        assets = []
        for asset_id, name in enumerate(REQUIRED_ASSETS, start=10):
            digest = "a" * 64
            if name == "SSRVPN-release-provenance.json":
                digest = hashlib.sha256(provenance_bytes).hexdigest()
            assets.append(
                {
                    "id": asset_id,
                    "name": name,
                    "size": len(provenance_bytes) if name.endswith(".json") else 1024,
                    "digest": f"sha256:{digest}",
                    "state": "uploaded",
                }
            )
        self.release_json.write_text(
            json.dumps(
                {
                    "id": 9,
                    "tag_name": TAG,
                    "draft": True,
                    "prerelease": False,
                    "assets": assets,
                }
            ),
            encoding="utf-8",
        )

        gh = self.bin_dir / "gh"
        gh.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
if [[ "$*" == *'/releases/tags/'* ]]; then
  if [ "$FAKE_GH_MODE" = public ]; then
    cat "$FAKE_RELEASE_JSON"
    exit 0
  fi
  if [ "$FAKE_GH_MODE" = network-failure ]; then
    echo 'gh: connection reset' >&2
    exit 1
  fi
  echo 'gh: Not Found (HTTP 404)' >&2
  exit 1
fi
if [[ "$*" == *'/releases/9'* ]]; then
  cat "$FAKE_RELEASE_JSON"
  exit 0
fi
if [[ "$*" == *'/releases?per_page=100'* ]]; then
  if [ "$FAKE_GH_MODE" = missing ]; then
    echo '[[]]'
  elif [ "$FAKE_GH_MODE" = duplicate ]; then
    printf '[['
    cat "$FAKE_RELEASE_JSON"
    printf ','
    cat "$FAKE_RELEASE_JSON"
    printf ']]\n'
  else
    printf '[['
    cat "$FAKE_RELEASE_JSON"
    printf ']]\n'
  fi
  exit 0
fi
if [[ "$*" == *'/releases/assets/'* ]]; then
  cat "$FAKE_PROVENANCE"
  exit 0
fi
echo 'gh: connection reset' >&2
exit 1
""",
            encoding="utf-8",
        )
        gh.chmod(0o755)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _run(
        self,
        mode: str = "hidden-draft",
        *extra_args: str,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "FAKE_GH_MODE": mode,
                "FAKE_GH_LOG": str(self.log),
                "FAKE_RELEASE_JSON": str(self.release_json),
                "FAKE_PROVENANCE": str(self.provenance),
                "GITHUB_API_RETRY_BASE_SECONDS": "0",
            }
        )
        return subprocess.run(
            [
                "python3",
                str(SCRIPT),
                "--repo",
                "Elegying/SSRVPN",
                "--tag",
                TAG,
                "--commit",
                COMMIT,
                "--work-dir",
                str(self.work_dir),
                "--github-output",
                str(self.github_output),
                *extra_args,
            ],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )

    def test_hidden_complete_draft_is_found_and_validated_by_asset_id(self) -> None:
        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text(encoding="utf-8")
        self.assertIn("--paginate --slurp", calls)
        self.assertIn("/releases/assets/16", calls)
        self.assertNotIn("release download", calls)
        outputs = self.github_output.read_text(encoding="utf-8")
        self.assertIn("release_id=9\n", outputs)
        self.assertRegex(outputs, r"release_identity=[0-9a-f]{64}\n")

    def test_exact_authorized_release_id_and_identity_can_be_revalidated(self) -> None:
        initial = self._run()
        self.assertEqual(initial.returncode, 0, initial.stderr)
        outputs = dict(
            line.split("=", 1)
            for line in self.github_output.read_text(encoding="utf-8").splitlines()
        )
        self.github_output.unlink()
        self.log.unlink()

        result = self._run(
            "exact",
            "--expected-release-id",
            outputs["release_id"],
            "--expected-release-identity",
            outputs["release_identity"],
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text(encoding="utf-8")
        self.assertIn("repos/Elegying/SSRVPN/releases/9", calls)
        self.assertNotIn("/releases/tags/", calls)

    def test_missing_release_uses_the_documented_non_error_exit(self) -> None:
        result = self._run("missing")

        self.assertEqual(result.returncode, 3, result.stderr)

    def test_public_release_uses_the_tag_endpoint_without_pagination(self) -> None:
        result = self._run("public")

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text(encoding="utf-8")
        self.assertNotIn("--paginate --slurp", calls)

    def test_duplicate_hidden_releases_fail_closed(self) -> None:
        result = self._run("duplicate")

        self.assertEqual(result.returncode, 1)
        self.assertIn("Multiple GitHub releases", result.stderr)

    def test_network_failure_is_not_treated_as_missing_release(self) -> None:
        result = self._run("network-failure")

        self.assertEqual(result.returncode, 1)
        self.assertIn("connection reset", result.stderr)

    def test_unfinished_asset_is_rejected_before_download(self) -> None:
        release = json.loads(self.release_json.read_text(encoding="utf-8"))
        release["assets"][0]["state"] = "starter"
        self.release_json.write_text(json.dumps(release), encoding="utf-8")

        result = self._run()

        self.assertEqual(result.returncode, 1)
        self.assertIn("not uploaded", result.stderr)
        calls = self.log.read_text(encoding="utf-8")
        self.assertNotIn("/releases/assets/", calls)


if __name__ == "__main__":
    unittest.main()
