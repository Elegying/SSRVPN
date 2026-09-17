import hashlib
import re
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

    def test_local_flutter_action_preserves_fixed_upstream_source(self) -> None:
        action_dir = ROOT / ".github/actions/setup-flutter"
        expected_blobs = {
            "setup.sh": "b3c0b7b688265169934775222e08146e08f69e79",
            "LICENSE": "c5366451ddd20de8ce61661e117410459a4ae913",
            "action.yaml": "644170e5eb88b15006d7f4fc748c6532b62d30c0",
        }
        for filename, expected in expected_blobs.items():
            content = (action_dir / filename).read_bytes()
            if filename == "action.yaml":
                content, count = re.subn(
                    rb"uses: actions/cache@[0-9a-f]{40}(?=\s)",
                    b"uses: actions/cache@v5",
                    content,
                )
                self.assertEqual(count, 2)
            header = f"blob {len(content)}\0".encode()
            self.assertEqual(hashlib.sha1(header + content).hexdigest(), expected)

    def test_local_flutter_action_recursively_pins_external_actions(self) -> None:
        visited = set()

        def check_action(directory: Path) -> None:
            if directory in visited:
                return
            visited.add(directory)
            manifest = directory / "action.yaml"
            if not manifest.exists():
                manifest = directory / "action.yml"
            references = re.findall(
                r"^\s*(?:-\s*)?uses:\s*([^\s#]+)",
                manifest.read_text(),
                flags=re.MULTILINE,
            )
            for reference in references:
                if reference.startswith("./"):
                    check_action(ROOT / reference)
                else:
                    self.assertRegex(reference, r"^[^@]+@[0-9a-f]{40}$")

        check_action(ROOT / ".github/actions/setup-flutter")

    def test_all_flutter_workflow_steps_use_the_local_pinned_action(self) -> None:
        for workflow, expected_count in (("ci.yml", 6), ("release.yml", 5)):
            source = (ROOT / ".github/workflows" / workflow).read_text()
            self.assertEqual(
                source.count("uses: ./.github/actions/setup-flutter"), expected_count
            )
            self.assertNotIn("uses: subosito/flutter-action@", source)

    def test_dependency_and_text_guards_gate_expensive_core_jobs(self) -> None:
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        preflight = ci.split("  dependency-preflight:\n", 1)[1].split("  shared:\n", 1)[0]
        self.assertIn("runs-on: ubuntu-latest", preflight)
        self.assertIn("needs: [changes, secret-scan]", preflight)
        self.assertNotIn("core-assets", preflight)
        for command in ("flutter pub get --enforce-lockfile", "check-version-sync.sh",
                        "check-android-built-in-kotlin.sh", "check-doc-consistency.sh"):
            self.assertIn(command, preflight)
        core = ci.split("  core-assets:\n", 1)[1].split("  macos-native:\n", 1)[0]
        self.assertIn("needs: [changes, dependency-preflight]", core)
        self.assertIn("if: always()", core)
        self.assertIn('run: test "$PREFLIGHT_RESULT" = success', core)
        self.assertLess(core.index('run: test "$PREFLIGHT_RESULT" = success'),
                        core.index("uses: actions/checkout@"))
        self.assertIn("bash scripts/bootstrap-core-assets.sh", core)
        self.assertNotIn("prepare-release-core-assets.sh", core)


if __name__ == "__main__":
    unittest.main()
