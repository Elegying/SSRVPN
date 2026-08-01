import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class QualityHygieneEntrypointTest(unittest.TestCase):
    def test_full_verification_runs_format_and_shell_lint_gate(self) -> None:
        verifier = (ROOT / "scripts" / "verify-all.sh").read_text(
            encoding="utf-8"
        )
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("scripts/check-quality-hygiene.sh", verifier)
        self.assertIn("bash scripts/check-quality-hygiene.sh", ci)

    def test_gate_checks_every_tracked_dart_and_shell_file(self) -> None:
        path = ROOT / "scripts" / "check-quality-hygiene.sh"
        self.assertTrue(path.is_file())
        source = path.read_text(encoding="utf-8")

        self.assertIn("git ls-files -z -- '*.dart'", source)
        self.assertIn("dart format --output=none --set-exit-if-changed", source)
        self.assertIn("git ls-files -z -- '*.sh'", source)
        self.assertIn("shellcheck", source)


if __name__ == "__main__":
    unittest.main()
