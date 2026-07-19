import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "run-flutter-coverage.sh"


class RunFlutterCoverageTests(unittest.TestCase):
    def _run(self, target: str) -> subprocess.CompletedProcess[str]:
        temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(temporary_directory.cleanup)
        fake_bin = Path(temporary_directory.name)
        capture = fake_bin / "capture.txt"
        flutter = fake_bin / "flutter"
        flutter.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "{ printf '%s\\n' \"$PWD\"; printf '%s\\n' \"$@\"; } > \"$CAPTURE\"\n",
            encoding="utf-8",
        )
        flutter.chmod(0o755)
        environment = os.environ.copy()
        environment["CAPTURE"] = str(capture)
        environment["PATH"] = f"{fake_bin}{os.pathsep}{environment['PATH']}"
        result = subprocess.run(
            ["bash", str(SCRIPT), target],
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        result.capture_lines = (
            capture.read_text(encoding="utf-8").splitlines()
            if capture.exists()
            else []
        )
        return result

    def test_desktop_targets_collect_owned_shared_part_coverage(self) -> None:
        expected_packages = {
            "SSRVPN_MacOS": "--coverage-package=^(ssrvpn_macos|ssrvpn_shared)$",
            "SSRVPN_Windows": "--coverage-package=^(ssrvpn_windows|ssrvpn_shared)$",
        }
        for target, package_argument in expected_packages.items():
            with self.subTest(target=target):
                result = self._run(target)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    result.capture_lines,
                    [
                        str(ROOT / target),
                        "test",
                        "--coverage",
                        package_argument,
                    ],
                )

    def test_non_desktop_targets_keep_package_local_coverage(self) -> None:
        for target in ("packages/ssrvpn_shared", "SSRVPN_Android"):
            with self.subTest(target=target):
                result = self._run(target)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    result.capture_lines,
                    [str(ROOT / target), "test", "--coverage"],
                )

    def test_unknown_target_is_rejected_before_flutter_runs(self) -> None:
        result = self._run("SSRVPN_Unknown")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown target", result.stderr)
        self.assertEqual(result.capture_lines, [])

    def test_verify_ci_and_release_use_the_single_coverage_entrypoint(self) -> None:
        files_and_minimum_calls = {
            ROOT / "scripts" / "verify-all.sh": 2,
            ROOT / ".github" / "workflows" / "ci.yml": 2,
            ROOT / ".github" / "workflows" / "release.yml": 4,
        }
        for path, minimum_calls in files_and_minimum_calls.items():
            with self.subTest(path=path):
                text = path.read_text(encoding="utf-8")
                self.assertGreaterEqual(
                    text.count("run-flutter-coverage.sh"),
                    minimum_calls,
                )
                self.assertNotIn("flutter test --coverage", text)


if __name__ == "__main__":
    unittest.main()
