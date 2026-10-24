#!/usr/bin/env python3
import struct
import unittest
import tempfile
import shutil
import subprocess
import os
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from scripts import macos_dmg_layout as layout


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
            'scripts/macos_dmg_layout.py" "$MOUNT_DIR"',
            'hdiutil attach "$RW_DMG_PATH" -nobrowse',
            'hdiutil attach "$VERSIONED_DMG_PATH" -readonly -nobrowse',
            '"$MOUNT_DIR" --verify-only',
            'Another $APP_NAME disk image is already mounted',
            'DMG layout verification failed',
        ):
            self.assertIn(required, script)

        self.assertNotIn("GUIDE_SOURCE", script)
        self.assertNotIn("GUIDE_NAME", script)
        self.assertNotIn("warning: Finder layout unavailable", script)
        self.assertNotIn('osascript', script)

    @unittest.skipIf(os.name == 'nt', 'POSIX package-guide entrypoint')
    def test_guide_gate_accepts_headless_layout_and_rejects_missing_guards(self):
        with tempfile.TemporaryDirectory(prefix='dmg-guide-') as folder:
            root = Path(folder)
            for name in ('scripts/check-package-guides.sh', 'SSRVPN_MacOS/DMG_README.txt',
                         'SSRVPN_Windows/USER_GUIDE.md', 'SSRVPN_MacOS/tool/package_macos.sh'):
                destination = root / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / name, destination)
            package = root / 'SSRVPN_MacOS/tool/package_macos.sh'
            original = package.read_text(encoding='utf-8')
            for text, code in ((original, 0), (original.replace('--verify-only', ''), 1),
                               (original + '\nosascript\n', 1)):
                package.write_text(text, encoding='utf-8')
                result = subprocess.run(['bash', str(root / 'scripts/check-package-guides.sh')],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)

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


class HeadlessDmgLayoutTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = layout.layout_tools()
        cls.tools.__enter__()

    @classmethod
    def tearDownClass(cls):
        cls.tools.__exit__(None, None, None)

    def setUp(self):
        from mac_alias import Alias, VolumeInfo, TargetInfo
        self.temp = tempfile.TemporaryDirectory(prefix='dmg layout 中文 ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'SSRVPN.app').mkdir()
        (self.root / 'Applications').symlink_to('/Applications', target_is_directory=True)
        (self.root / '.background').mkdir()
        (self.root / '.background/background.png').write_bytes(BACKGROUND.read_bytes())
        date = datetime(2026, 1, 1, tzinfo=timezone.utc)
        alias = Alias(
            volume=VolumeInfo('SSRVPN', date, b'H+', 0, 0, b'\0\0', posix_path=str(self.root)),
            target=TargetInfo(0, 'background.png', 16, 17, date, b'\0'*4, b'\0'*4,
                              posix_path='/.background/background.png'),
        )
        patch = mock.patch.object(Alias, 'for_file', return_value=alias)
        patch.start()
        self.addCleanup(patch.stop)

    def test_round_trip_preserves_branded_layout_without_finder(self):
        from ds_store import DSStore
        layout.write_layout(self.root)
        layout.verify_layout(self.root)
        with DSStore.open(str(self.root / '.DS_Store'), 'r') as store:
            self.assertEqual(store['SSRVPN.app']['Iloc'], (175, 190))
            self.assertEqual(store['Applications']['Iloc'], (485, 190))
            self.assertEqual(store['.']['bwsp']['WindowBounds'], '{{100, 100}, {660, 400}}')
            self.assertEqual(store['.']['icvp']['iconSize'], 112)
        self.assertNotIn(str(self.root).encode(), (self.root / '.DS_Store').read_bytes())

    def test_corrupt_or_changed_layout_fails_closed(self):
        from ds_store import DSStore
        for code, value in [('Iloc', (0, 0)), ('Iloc', (485, 190))]:
            layout.write_layout(self.root)
            with DSStore.open(str(self.root / '.DS_Store'), 'r+') as store:
                store['SSRVPN.app'][code] = value
            with self.assertRaises(ValueError):
                layout.verify_layout(self.root)
        (self.root / '.DS_Store').write_bytes(b'broken')
        with self.assertRaises(Exception):
            layout.verify_layout(self.root)

    def test_missing_background_wrong_link_and_extra_item_are_rejected(self):
        background = self.root / '.background/background.png'
        background.unlink()
        with self.assertRaises(ValueError):
            layout.write_layout(self.root)

        self.assertFalse((self.root / '.DS_Store').exists())
        background.write_bytes(BACKGROUND.read_bytes())
        link = self.root / 'Applications'
        link.unlink()
        link.symlink_to('/tmp', target_is_directory=True)
        with self.assertRaises(ValueError):
            layout.write_layout(self.root)
        link.unlink()
        link.symlink_to('/Applications', target_is_directory=True)
        (self.root / 'unexpected.txt').write_text('unexpected')
        with self.assertRaises(ValueError):
            layout.write_layout(self.root)

    def test_window_and_background_metadata_tampering_is_rejected(self):
        from ds_store import DSStore
        from mac_alias import Alias
        for change in ('bounds', 'background', 'size'):
            layout.write_layout(self.root)
            with DSStore.open(str(self.root / '.DS_Store'), 'r+') as store:
                if change == 'bounds':
                    record = dict(store['.']['bwsp'], WindowBounds='{{0, 0}, {1, 1}}')
                    store['.']['bwsp'] = record
                else:
                    record = store['.']['icvp']
                    if change == 'size':
                        record['iconSize'] = 16
                    else:
                        alias = Alias.from_bytes(record['backgroundImageAlias'])
                        alias.target.posix_path = '/outside.png'
                        record['backgroundImageAlias'] = alias.to_bytes()
                    store['.']['icvp'] = record
            with self.assertRaises(ValueError):
                layout.verify_layout(self.root)



if __name__ == "__main__":
    unittest.main()
