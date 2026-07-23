import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "check-release-assets.sh"


class CheckReleaseAssetsTests(unittest.TestCase):
    def test_rejects_noncanonical_release_assets(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn(
            "unexpected = sorted(set(assets) - required - allowed_retired)",
            source,
        )

    def test_only_rollback_may_tolerate_retired_windows_zip_assets(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        rollback = (ROOT / ".github" / "workflows" / "maintenance.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("SSRVPN_ALLOW_RETIRED_WINDOWS_ZIP", source)
        self.assertIn("SSRVPN_ALLOW_RETIRED_WINDOWS_ZIP: '1'", rollback)

    def test_retries_gh_and_verifies_local_downloads(self) -> None:
        digest = "a" * 64
        tag = "v9.8.7"
        artifact_names = (
            "SSRVPN.apk",
            "SSRVPN.dmg",
            "SSRVPN_Setup.exe",
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = Path(temporary_directory)
            asset_directory = temporary / "fixtures"
            asset_directory.mkdir()
            assets = []
            for name in artifact_names:
                assets.extend(
                    (
                        {"name": name, "size": 1, "digest": f"sha256:{digest}"},
                        {"name": f"{name}.sha256", "size": 77},
                    )
                )
                (asset_directory / f"{name}.sha256").write_text(
                    f"{digest}  {name}\n",
                    encoding="ascii",
                )

            assets.append(
                {"name": "SSRVPN-release-provenance.json", "size": 461}
            )
            (asset_directory / "SSRVPN-release-provenance.json").write_text(
                json.dumps(
                    {
                        "schema": 1,
                        "tag": tag,
                        "commit": "b" * 40,
                        "assets": {name: digest for name in artifact_names},
                    }
                ),
                encoding="utf-8",
            )

            release_path = temporary / "release.json"
            release_path.write_text(
                json.dumps({"tag_name": tag, "assets": assets}),
                encoding="utf-8",
            )
            fake_gh = temporary / "gh"
            fake_gh.write_text(
                """#!/bin/sh
set -eu

fail_once() {
  state_file="$1"
  if [ ! -f "$state_file" ]; then
    : > "$state_file"
    return 0
  fi
  return 1
}

if [ "${1:-}" = api ]; then
  if fail_once "$FAKE_GH_API_STATE"; then
    exit 1
  fi
  cat "$FAKE_RELEASE_JSON"
  exit 0
fi

if [ "${1:-}" = release ] && [ "${2:-}" = download ]; then
  if fail_once "$FAKE_GH_DOWNLOAD_STATE"; then
    exit 1
  fi
  shift 3
  destination=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --dir ]; then
      destination="$2"
      shift 2
    else
      shift
    fi
  done
  cp "$FAKE_ASSET_DIRECTORY"/* "$destination/"
  exit 0
fi

exit 2
""",
                encoding="utf-8",
            )
            fake_gh.chmod(fake_gh.stat().st_mode | stat.S_IXUSR)

            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{temporary}{os.pathsep}{environment['PATH']}",
                    "FAKE_RELEASE_JSON": str(release_path),
                    "FAKE_ASSET_DIRECTORY": str(asset_directory),
                    "FAKE_GH_API_STATE": str(temporary / "api-state"),
                    "FAKE_GH_DOWNLOAD_STATE": str(temporary / "download-state"),
                    "PYTHON_BIN": os.fsdecode(sys.executable),
                }
            )
            result = subprocess.run(
                ["bash", str(SCRIPT), tag],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            f"Release {tag} has all required SSRVPN assets",
            result.stdout,
        )


if __name__ == "__main__":
    unittest.main()
