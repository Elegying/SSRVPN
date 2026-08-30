import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts" / "check-flutter-version.sh"
EXPECTED = json.loads((ROOT / ".fvmrc").read_text(encoding="utf-8"))["flutter"]


class FlutterVersionPreflightTest(unittest.TestCase):
    def run_check(self, version: str, *, valid_json: bool = True) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "flutter"
            payload = json.dumps({"frameworkVersion": version}) if valid_json else "not-json"
            fake.write_text(
                "#!/usr/bin/env bash\n"
                "if [[ \"${1:-}\" != --version || \"${2:-}\" != --machine ]]; then exit 9; fi\n"
                f"printf '%s\\n' '{payload}'\n",
                encoding="utf-8",
            )
            fake.chmod(0o755)
            environment = os.environ.copy()
            environment["SSRVPN_FLUTTER_BIN"] = str(fake)
            return subprocess.run(
                ["bash", str(CHECK)],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

    def test_accepts_only_the_exact_fvm_version(self) -> None:
        result = self.run_check(EXPECTED)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"version verified: {EXPECTED}", result.stdout)

    def test_rejects_a_different_stable_version_with_remediation(self) -> None:
        result = self.run_check("3.47.2")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"expected {EXPECTED}", result.stderr)
        self.assertIn("got 3.47.2", result.stderr)
        self.assertIn("fvm exec make verify", result.stderr)

    def test_rejects_invalid_machine_output(self) -> None:
        result = self.run_check(EXPECTED, valid_json=False)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid JSON", result.stderr)

    def test_full_verification_checks_toolchain_before_every_other_step(self) -> None:
        entrypoint = (ROOT / "scripts" / "verify-all.sh").read_text(
            encoding="utf-8"
        )
        steps = [
            line
            for line in entrypoint.splitlines()
            if line.startswith('run_step "')
        ]

        self.assertTrue(steps)
        self.assertEqual(
            steps[0],
            'run_step "Flutter toolchain version" scripts/check-flutter-version.sh',
        )
        self.assertLess(
            entrypoint.index("scripts/check-flutter-version.sh"),
            entrypoint.index("flutter pub get --enforce-lockfile"),
        )

    def test_ci_and_release_use_the_same_exact_fvm_version(self) -> None:
        for relative in (
            ".github/workflows/ci.yml",
            ".github/workflows/release.yml",
        ):
            workflow = (ROOT / relative).read_text(encoding="utf-8")
            match = re.search(r"^  FLUTTER_VERSION: '([^']+)'$", workflow, re.MULTILINE)
            self.assertIsNotNone(match, relative)
            self.assertEqual(match.group(1), EXPECTED, relative)


if __name__ == "__main__":
    unittest.main()
