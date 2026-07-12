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
    def test_windows_installer_and_portable_assets_are_documented(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            changelog = Path(directory, "CHANGELOG.md")
            changelog.write_text(
                "# Changelog\n\n## [3.1.0] - 2026-07-12\n\n### Added\n- Update\n",
                encoding="utf-8",
            )

            notes = MODULE.build_release_notes(changelog, "v3.1.0")

            self.assertIn("`SSRVPN_Setup.exe`", notes)
            self.assertIn("`SSRVPN_Setup.exe.sha256`", notes)
            self.assertIn("`SSRVPN.zip`", notes)
            self.assertIn("`SSRVPN.zip.sha256`", notes)


if __name__ == "__main__":
    unittest.main()
