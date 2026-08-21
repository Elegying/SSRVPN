import re
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
        self.assertLess(
            verifier.index(
                'run_step "Workspace pub get" '
                "flutter pub get --enforce-lockfile"
            ),
            verifier.index(
                'run_step "Source formatting and shell lint" '
                "scripts/check-quality-hygiene.sh"
            ),
        )
        self.assertLess(
            ci.index("- run: flutter pub get --enforce-lockfile"),
            ci.index("- run: bash scripts/check-quality-hygiene.sh"),
        )

    def test_gate_checks_every_tracked_dart_and_shell_file(self) -> None:
        path = ROOT / "scripts" / "check-quality-hygiene.sh"
        self.assertTrue(path.is_file())
        source = path.read_text(encoding="utf-8")

        self.assertIn("git ls-files -z -- '*.dart'", source)
        self.assertIn("dart format --output=none --set-exit-if-changed", source)
        self.assertIn("git ls-files -z -- '*.sh'", source)
        self.assertIn("shellcheck", source)
        self.assertIn('.dart_tool/package_config.json', source)
        self.assertIn('flutter pub get --enforce-lockfile', source)

    def test_protected_dependency_installs_enforce_committed_lockfile(self) -> None:
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )
        release = (
            ROOT / ".github" / "workflows" / "release.yml"
        ).read_text(encoding="utf-8")
        verifier = (ROOT / "scripts" / "verify-all.sh").read_text(
            encoding="utf-8"
        )
        hygiene = (
            ROOT / "scripts" / "check-quality-hygiene.sh"
        ).read_text(encoding="utf-8")
        android_release = (
            ROOT / "SSRVPN_Android" / "build_release.sh"
        ).read_text(encoding="utf-8")
        windows_release = (
            ROOT / "SSRVPN_Windows" / "tool" / "package_windows.ps1"
        ).read_text(encoding="utf-8")

        protected_sources = {
            ".github/workflows/ci.yml": ci,
            ".github/workflows/release.yml": release,
            "scripts/verify-all.sh": verifier,
            "scripts/check-quality-hygiene.sh": hygiene,
            "SSRVPN_Android/build_release.sh": android_release,
        }
        unguarded_pub_get = re.compile(
            r"\b(?:flutter|dart) pub get\b(?![^\n]*--enforce-lockfile)"
        )
        for relative_path, source in protected_sources.items():
            with self.subTest(source=relative_path):
                self.assertIsNone(unguarded_pub_get.search(source))

        locked_get = "flutter pub get --enforce-lockfile"
        self.assertEqual(4, ci.count(locked_get))
        self.assertEqual(4, release.count(locked_get))
        self.assertNotIn("dart pub get", release)
        self.assertIn(
            "$arguments = @('pub', 'get', '--enforce-lockfile')",
            windows_release,
        )
        self.assertIn(
            "run flutter pub get at the workspace", windows_release
        )
        self.assertIn("review and commit pubspec.lock", windows_release)

    def test_developer_workspace_commands_remain_convenient(self) -> None:
        workspace = (ROOT / "scripts" / "workspace.sh").read_text(
            encoding="utf-8"
        )
        self.assertGreaterEqual(workspace.count("flutter pub get"), 2)
        self.assertNotIn("--enforce-lockfile", workspace)

    def test_every_dart_target_enables_strict_language_analysis(self) -> None:
        for relative_path in (
            "SSRVPN_Android/analysis_options.yaml",
            "SSRVPN_MacOS/analysis_options.yaml",
            "SSRVPN_Windows/analysis_options.yaml",
            "packages/ssrvpn_shared/analysis_options.yaml",
        ):
            options = (ROOT / relative_path).read_text(encoding="utf-8")
            with self.subTest(options=relative_path):
                self.assertIn("strict-casts: true", options)
                self.assertIn("strict-inference: true", options)
                self.assertIn("strict-raw-types: true", options)

    def test_exit_trap_callback_is_portable_across_shellcheck_versions(self) -> None:
        native_gate = (ROOT / "scripts" / "test-macos-native.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("shellcheck disable=SC2317,SC2329", native_gate)
        self.assertIn("trap cleanup EXIT", native_gate)


if __name__ == "__main__":
    unittest.main()
