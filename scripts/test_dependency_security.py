import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class DependencySecurityTest(unittest.TestCase):
    def test_pull_requests_block_moderate_or_higher_dependency_risk(self) -> None:
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("dependency-review:", ci)
        self.assertIn(
            "actions/dependency-review-action@"
            "a1d282b36b6f3519aa1f3fc636f609c47dddb294",
            ci,
        )
        self.assertIn("fail-on-severity: moderate", ci)
        self.assertIn("license-check: true", ci)

    def test_dependabot_tracks_actions_and_the_pub_workspace(self) -> None:
        dependabot = (ROOT / ".github" / "dependabot.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn('package-ecosystem: "github-actions"', dependabot)
        self.assertIn('package-ecosystem: "pub"', dependabot)


if __name__ == "__main__":
    unittest.main()
