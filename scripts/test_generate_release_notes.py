import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("generate-release-notes.py")
SPEC = importlib.util.spec_from_file_location("release_notes", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class GenerateReleaseNotesTest(unittest.TestCase):
    def test_generic_entries_rejected_even_beside_real_changes(self):
        for placeholder in ["优化稳定性，提升连接体验。", "**修复已知问题**", "TODO", "优化用户体验"]:
            with self.subTest(placeholder=placeholder), self.assertRaises(SystemExit):
                MODULE.validate_release_notes("- " + placeholder + "\n- 修复 Windows 代理恢复失败。")

    def test_specific_change_and_impact_allowed(self):
        MODULE.validate_release_notes("- 修复断开后代理未恢复的问题，提升连接体验。")

    def test_headings_alone_rejected(self):
        with self.assertRaises(SystemExit):
            MODULE.validate_release_notes("### 修复\n<!-- 待补充 -->")

    def test_empty_release_section_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            changelog = Path(directory, "CHANGELOG.md")
            changelog.write_text(
                "# Changelog\n\n## [3.1.0] - 2026-07-12\n\n## [3.0.0]\n- Old\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(SystemExit, "release notes are empty"):
                MODULE.build_release_notes(changelog, "v3.1.0")

    def test_windows_installer_is_the_only_windows_asset_documented(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            changelog = Path(directory, "CHANGELOG.md")
            changelog.write_text(
                "# Changelog\n\n## [3.1.0] - 2026-07-12\n\n### Added\n- 修复 Windows 断开后未恢复原有代理的问题。\n",
                encoding="utf-8",
            )

            notes = MODULE.build_release_notes(changelog, "v3.1.0")

            self.assertIn("`SSRVPN_Setup.exe`", notes)
            self.assertIn("`SSRVPN_Setup.exe.sha256`", notes)
            self.assertIn(
                r"Get-FileHash .\SSRVPN_Setup.exe -Algorithm SHA256",
                notes,
            )
            self.assertIn("Linux：`sha256sum -c <file>.sha256`", notes)
            self.assertNotIn("`SSRVPN.zip`", notes)
            self.assertNotIn("`SSRVPN.zip.sha256`", notes)


class PublishedReleaseNotesTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location(
            "verify_notes", SCRIPT.with_name("verify-release-notes.py"))
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.notes = "## SSRVPN v6.0.9\n\n- 修复 Windows 代理恢复失败。"
        self.release = {"tag_name": "v6.0.9", "body": self.notes}
        self.manifest = {"version": "6.0.9", "changelog": self.notes}

    def test_same_body_with_final_newline_passes(self):
        self.module.verify(self.notes + "\n", "v6.0.9", self.release,
                           [self.manifest, self.manifest])

    def test_drift_missing_text_and_wrong_version_fail(self):
        for field, value in [("body", "old"), ("body", ""), ("tag_name", "v6.0.8")]:
            with self.subTest(field=field, value=value), self.assertRaises(SystemExit):
                self.module.verify(self.notes, "v6.0.9",
                                   {**self.release, field: value}, [self.manifest])
        for field, value in [("changelog", "old"), ("changelog", ""), ("version", "6.0.8")]:
            with self.subTest(field=field, value=value), self.assertRaises(SystemExit):
                self.module.verify(self.notes, "v6.0.9", self.release,
                                   [self.manifest, {**self.manifest, field: value}])

    def test_workflows_enforce_checks_before_mutation_and_after_publication(self):
        root = SCRIPT.parent.parent
        prepare = (root / ".github/workflows/prepare-release.yml").read_text()
        self.assertLess(prepare.index("generate-release-notes.py"), prepare.index("run: bash scripts/prepare-release.sh"))
        release = (root / ".github/workflows/release.yml").read_text()
        promotion = release.split("- name: Promote OSS public channel and finalize GitHub Release", 1)[1]
        self.assertLess(promotion.index("verify-release-notes.py"), promotion.index("OSS_BACKUP_DIR="))
        self.assertEqual(release.count("scripts/verify-release-notes.py"), 2)
        self.assertIn('--manifest "$manifest_json"', promotion)
        self.assertIn('--manifest "$RUNNER_TEMP/published-versioned-notes.json"', promotion)


if __name__ == "__main__":
    unittest.main()
