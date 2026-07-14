import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GITLEAKS_ACTION = (
    "gitleaks/gitleaks-action@"
    "ff98106e4c7b2bc287b24eaf42907196329070c7"
)


class SecretScanningTest(unittest.TestCase):
    def test_gitleaks_extends_defaults_and_scopes_vpn_fixture_allowlist(self) -> None:
        config = (ROOT / ".gitleaks.toml").read_text(encoding="utf-8")

        self.assertIn("useDefault = true", config)
        self.assertIn('id = "vpn-subscription-uri"', config)
        self.assertIn("[[rules.allowlists]]", config)
        self.assertIn("(test|tests)", config)

    def test_ci_and_release_scan_full_history_with_pinned_action(self) -> None:
        for name in ("ci.yml", "release.yml"):
            workflow = (ROOT / ".github" / "workflows" / name).read_text(
                encoding="utf-8"
            )
            self.assertIn(GITLEAKS_ACTION, workflow)
            self.assertIn("fetch-depth: 0", workflow)


if __name__ == "__main__":
    unittest.main()
