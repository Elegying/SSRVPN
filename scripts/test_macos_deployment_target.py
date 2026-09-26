import gzip
import plistlib
import struct
import tempfile
import unittest
from pathlib import Path

from scripts.check_macos_deployment_target import check_app, minimum_versions


def macho(major, minor=0):
    return struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 6, 1, 24, 0, 0) + struct.pack('<6I', 0x32, 24, 1, (major << 16) | (minor << 8), 0, 0)


class DeploymentTargetTests(unittest.TestCase):
    def test_all_universal_slices_are_checked(self):
        first, second = macho(12), macho(14)
        data = struct.pack('>2I', 0xcafebabe, 2)
        data += struct.pack('>5I', 0x100000c, 0, 48, len(first), 0)
        data += struct.pack('>5I', 0x1000007, 0, 48 + len(first), len(second), 0)
        self.assertEqual(minimum_versions(data + first + second), [(12, 0, 0), (14, 0, 0)])

    def test_malformed_or_missing_version_fails(self):
        for data in [b'not executable', macho(13)[:40], macho(13)[:32], macho(13)[:16]]:
            with self.subTest(data=data), self.assertRaises((ValueError, struct.error)):
                minimum_versions(data)

    def test_app_frameworks_and_compressed_core_respect_declared_floor(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'SSRVPN.app'
            main = app / 'Contents/MacOS/SSRVPN'
            core = app / 'Contents/Frameworks/App.framework/Resources/flutter_assets/assets/AtlasCore.gz'
            dependency = app / 'Contents/Frameworks/objective_c.framework/objective_c'
            for path in [main, core, dependency]:
                path.parent.mkdir(parents=True, exist_ok=True)
            info = app / 'Contents/Info.plist'
            info.write_bytes(plistlib.dumps({'LSMinimumSystemVersion': '13.0', 'CFBundleExecutable': 'SSRVPN'}))
            main.write_bytes(macho(13))
            core.write_bytes(gzip.compress(macho(12)))
            dependency.write_bytes(macho(13))
            self.assertEqual(check_app(app), 3)
            dependency.write_bytes(macho(14))
            with self.assertRaisesRegex(ValueError, 'objective_c'):
                check_app(app)
            dependency.write_bytes(macho(13))
            core.write_bytes(gzip.compress(macho(14)))
            with self.assertRaisesRegex(ValueError, 'AtlasCore'):
                check_app(app)
            info.write_bytes(plistlib.dumps({'LSMinimumSystemVersion': '11.0', 'CFBundleExecutable': 'SSRVPN'}))
            with self.assertRaisesRegex(ValueError, 'must declare macOS 13.0'):
                check_app(app)
