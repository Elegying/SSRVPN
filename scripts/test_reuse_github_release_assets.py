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
    "SSRVPN.zip",
)
CERT = "ab" * 32
COMMIT = "c" * 40


class ReuseGithubReleaseAssetsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.assets = self.root / "release-assets"
        self.artifacts = self.root / "artifacts"
        self.bin_dir = self.root / "bin"
        self.android_home = self.root / "android-sdk"
        for directory in (
            self.assets,
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
if [ "$1" = api ]; then
  case "$FAKE_API_MODE" in
    found) cat "$FAKE_RELEASE_JSON" ;;
    missing) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
    *) echo 'gh: connection reset' >&2; exit 1 ;;
  esac
elif [ "$1" = release ] && [ "$2" = delete ]; then
  touch "$FAKE_DELETE_MARKER"
elif [ "$1" = release ] && [ "$2" = download ]; then
  shift 2
  destination=''
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --dir ]; then destination="$2"; shift 2; else shift; fi
  done
  cp "$FAKE_RELEASE_ASSETS"/* "$destination/"
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
            assets.append(
                {
                    "name": path.name,
                    "size": path.stat().st_size,
                    "digest": f"sha256:{digest}",
                }
            )
        self.release_json.write_text(
            json.dumps(
                {"draft": draft, "prerelease": prerelease, "assets": assets}
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
                "FAKE_RELEASE_ASSETS": str(self.assets),
                "FAKE_DELETE_MARKER": str(self.delete_marker),
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
            ("SSRVPN.zip", "windows"),
        ):
            self.assertEqual(
                (self.artifacts / platform / name).read_bytes(),
                (self.assets / name).read_bytes(),
            )

    def test_partial_draft_is_deleted_without_deleting_the_tag(self) -> None:
        self._write_release(draft=True, missing="SSRVPN.dmg")
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

    def test_prerelease_is_never_reused_or_promoted(self) -> None:
        self._write_release(draft=False, prerelease=True)

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


if __name__ == "__main__":
    unittest.main()
