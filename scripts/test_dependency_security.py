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

    def test_sdk_bound_and_android_toolchain_updates_are_separate(self) -> None:
        dependabot = (ROOT / ".github/dependabot.yml").read_text()
        for group, ordinary, packages in (
            ("flutter-sdk-bound", "pub-minor-patch", ("meta", "characters", "collection", "test")),
            ("android-toolchain", "android-gradle-minor-patch",
             ("com.android.*", "org.jetbrains.kotlin.*", "org.gradle.*", "gradle")),
        ):
            isolated = dependabot.split(f"      {group}:\n", 1)[1].split(f"      {ordinary}:\n", 1)[0]
            general = dependabot.split(f"      {ordinary}:\n", 1)[1].split("    ignore:\n", 1)[0]
            self.assertIn("exclude-patterns:", general)
            for package in packages:
                self.assertIn(f'- "{package}"', isolated)
                self.assertIn(f'- "{package}"', general.split("exclude-patterns:", 1)[1])

    def test_dependency_and_text_guards_gate_expensive_core_jobs(self) -> None:
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        preflight = ci.split("  dependency-preflight:\n", 1)[1].split("  shared:\n", 1)[0]
        self.assertIn("runs-on: ubuntu-latest", preflight)
        self.assertIn("needs: secret-scan", preflight)
        self.assertNotIn("core-assets", preflight)
        for command in ("flutter pub get --enforce-lockfile", "check-version-sync.sh",
                        "check-android-built-in-kotlin.sh", "check-doc-consistency.sh"):
            self.assertIn(command, preflight)
        core = ci.split("  core-assets:\n", 1)[1].split("  macos-native:\n", 1)[0]
        self.assertIn("needs: dependency-preflight", core)
        self.assertIn("if: always()", core)
        self.assertIn('run: test "$PREFLIGHT_RESULT" = success', core)
        self.assertLess(core.index('run: test "$PREFLIGHT_RESULT" = success'),
                        core.index("uses: actions/checkout@"))
        self.assertIn("bash scripts/bootstrap-core-assets.sh", core)
        self.assertNotIn("prepare-release-core-assets.sh", core)


if __name__ == "__main__":
    unittest.main()
