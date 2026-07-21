#!/usr/bin/env python3
import struct
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BACKGROUND = ROOT / "SSRVPN_MacOS" / "tool" / "dmg" / "background.png"
PACKAGE_SCRIPT = ROOT / "SSRVPN_MacOS" / "tool" / "package_macos.sh"
SMOKE_SCRIPT = ROOT / "scripts" / "smoke-release-artifacts.sh"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"


class MacosDmgLayoutTest(unittest.TestCase):
    def test_background_is_the_expected_finder_canvas(self) -> None:
        data = BACKGROUND.read_bytes()
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        width, height = struct.unpack(">II", data[16:24])
        self.assertEqual((width, height), (660, 400))

    def test_packaging_requires_the_branded_two_item_layout(self) -> None:
        script = PACKAGE_SCRIPT.read_text(encoding="utf-8")

        for required in (
            'DMG_BACKGROUND_SOURCE="$PROJECT_ROOT/tool/dmg/background.png"',
            'test -f "$DMG_BACKGROUND_SOURCE"',
            'set background picture of icon view options of dmgWindow',
            'set the bounds of dmgWindow to {100, 100, 760, 522}',
            'set position of item "$APP_NAME.app" of dmgFolder to {175, 190}',
            'set position of item "Applications" of dmgFolder to {485, 190}',
            'Another $APP_NAME disk image is already mounted',
            'DMG Finder layout failed',
        ):
            self.assertIn(required, script)

        self.assertNotIn("GUIDE_SOURCE", script)
        self.assertNotIn("GUIDE_NAME", script)
        self.assertNotIn("warning: Finder layout unavailable", script)

    def test_local_and_github_smoke_checks_reject_the_old_tutorial_item(self) -> None:
        smoke = SMOKE_SCRIPT.read_text(encoding="utf-8")
        workflow = RELEASE_WORKFLOW.read_text(encoding="utf-8")

        for source in (smoke, workflow):
            self.assertIn('test ! -e "$MOUNT_DIR/安装教程.txt"', source)
            self.assertIn('test ! -e "$MOUNT_DIR/使用教程.txt"', source)
            self.assertIn(
                'grep -aFq "background.png" "$MOUNT_DIR/.DS_Store"',
                source,
            )
            self.assertIn('top_level_count="$(find "$MOUNT_DIR"', source)
            self.assertIn('[[ "$top_level_count" -eq 2 ]]', source)


if __name__ == "__main__":
    unittest.main()
