import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("generate-oss-release-manifest.py")
SPEC = importlib.util.spec_from_file_location("oss_manifest", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class GenerateOssReleaseManifestTest(unittest.TestCase):
    def test_builds_manifest_from_verified_assets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            asset = Path(directory, "SSRVPN.apk")
            asset.write_bytes(b"apk")
            checksum = hashlib.sha256(b"apk").hexdigest()
            Path(f"{asset}.sha256").write_text(
                f"{checksum}  SSRVPN.apk\n", encoding="utf-8"
            )

            manifest = MODULE.build_manifest(
                tag="v3.1.0",
                base_url="https://download.example/ssrvpn/releases/v3.1.0",
                changelog=" fixed ",
                assets=[asset],
            )

            self.assertEqual(manifest["version"], "3.1.0")
            self.assertEqual(manifest["changelog"], "fixed")
            self.assertEqual(
                manifest["assets"],
                [
                    {
                        "name": "SSRVPN.apk",
                        "url": "https://download.example/ssrvpn/releases/v3.1.0/SSRVPN.apk",
                        "sha256": checksum,
                    }
                ],
            )

    def test_rejects_checksum_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            asset = Path(directory, "SSRVPN_Setup.exe")
            asset.write_bytes(b"installer")
            Path(f"{asset}.sha256").write_text("0" * 64, encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                MODULE.build_manifest(
                    tag="v3.1.0",
                    base_url="https://download.example/releases/v3.1.0",
                    changelog="",
                    assets=[asset],
                )

    def test_release_publishes_and_verifies_stable_download_aliases(self) -> None:
        workflow = (
            SCRIPT.parents[1] / ".github" / "workflows" / "release.yml"
        ).read_text(encoding="utf-8")
        promoter = (
            SCRIPT.parents[1] / "scripts" / "promote-oss-public-channel.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("scripts/promote-oss-public-channel.sh", workflow)
        self.assertIn('stable_prefix="$OSS_PREFIX/downloads"', promoter)
        self.assertIn('--cache-control "no-cache"', promoter)
        self.assertIn('cmp "$source" "$downloaded"', promoter)
        for name in (
            "SSRVPN.apk",
            "SSRVPN.dmg",
            "SSRVPN_Setup.exe",
        ):
            self.assertIn(name, workflow)


if __name__ == "__main__":
    unittest.main()
