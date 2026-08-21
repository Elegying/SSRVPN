import base64
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "create-android-release-keystore.sh"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
SENTINEL = b"private-keystore-material"


class AndroidReleaseKeystoreTests(unittest.TestCase):
    def test_keystore_is_private_and_secret_material_is_not_printed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            keytool = fake_bin / "keytool"
            keytool.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env bash
                    set -euo pipefail
                    while [ "$#" -gt 0 ]; do
                      if [ "$1" = -keystore ]; then
                        shift
                        printf 'private-keystore-material' > "$1"
                        exit 0
                      fi
                      shift
                    done
                    exit 2
                    """
                ),
                encoding="utf-8",
            )
            keytool.chmod(keytool.stat().st_mode | stat.S_IXUSR)
            output = root / "release.jks"
            environment = os.environ.copy()
            environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"

            result = subprocess.run(
                ["/bin/bash", "-c", 'umask 022; exec "$1" "$2"', "test", str(SCRIPT), str(output)],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
            combined = result.stdout + result.stderr
            self.assertNotIn(SENTINEL.decode(), combined)
            self.assertNotIn(base64.b64encode(SENTINEL).decode(), combined)
            self.assertIn("gh secret set ANDROID_KEYSTORE_BASE64", combined)

            repeated = subprocess.run(
                [str(SCRIPT), str(output)],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertNotEqual(repeated.returncode, 0)
            self.assertIn("Refusing to overwrite", repeated.stderr)

    def test_release_workflow_limits_and_cleans_signing_files(self) -> None:
        workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")
        signing = workflow[workflow.index("Prepare Android release signing") :]
        self.assertIn("umask 077", signing)
        self.assertIn('chmod 600 "$KEYSTORE_PATH"', signing)
        self.assertIn("Cleanup Android signing files", signing)
        self.assertIn("if: always()", signing)
        self.assertIn('rm -f "$RUNNER_TEMP/ssrvpn-release.jks"', signing)
        self.assertIn("SSRVPN_Android/android/key.properties", signing)


if __name__ == "__main__":
    unittest.main()
