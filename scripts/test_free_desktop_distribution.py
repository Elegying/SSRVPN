import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class FreeDesktopDistributionTest(unittest.TestCase):
    def test_pull_requests_compile_the_native_macos_app(self) -> None:
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("Build macOS app", ci)
        self.assertIn("matrix.directory == 'SSRVPN_MacOS'", ci)
        self.assertIn("flutter build macos --debug", ci)

    def test_paid_desktop_signing_automation_is_absent(self) -> None:
        active_files = [
            ROOT / ".github" / "workflows" / "ci.yml",
            ROOT / ".github" / "workflows" / "release.yml",
            ROOT / "scripts" / "verify-all.sh",
            ROOT / "SSRVPN_MacOS" / "tool" / "package_macos.sh",
            ROOT / "SSRVPN_Windows" / "tool" / "package_windows.ps1",
            ROOT / "SSRVPN_Windows" / "tool" / "build_installer.ps1",
        ]
        forbidden = (
            "ENABLE_MACOS_SIGNING",
            "MACOS_SIGNING_ENABLED",
            "MACOS_SIGNING_IDENTITY",
            "APPLE_NOTARY_",
            "notarytool",
            "ENABLE_WINDOWS_SIGNING",
            "WINDOWS_SIGNING_ENABLED",
            "WINDOWS_SIGNING_CERTIFICATE_PATH",
            "sign_windows_artifacts.ps1",
            "validate_release_signing.py",
            "check-release-signing-automation.sh",
        )

        for path in active_files:
            content = path.read_text(encoding="utf-8")
            for token in forbidden:
                with self.subTest(file=path.name, token=token):
                    self.assertNotIn(token, content)

        mac_package = active_files[3].read_text(encoding="utf-8")
        self.assertIn("codesign --force --deep --sign -", mac_package)

        for removed in (
            "scripts/check-release-signing-automation.sh",
            "scripts/sign_windows_artifacts.ps1",
            "scripts/validate_release_signing.py",
            "scripts/test_validate_release_signing.py",
        ):
            self.assertFalse((ROOT / removed).exists(), removed)

    def test_windows_distribution_is_installer_only(self) -> None:
        active_release_files = (
            ROOT / ".github" / "workflows" / "ci.yml",
            ROOT / ".github" / "workflows" / "release.yml",
            ROOT / ".github" / "workflows" / "oss-rollback.yml",
            ROOT / "scripts" / "generate-release-notes.py",
            ROOT / "scripts" / "reuse-github-release-assets.sh",
            ROOT / "scripts" / "validate-existing-release-retry.py",
            ROOT / "SSRVPN_Windows" / "tool" / "package_windows.ps1",
        )

        for path in active_release_files:
            content = path.read_text(encoding="utf-8")
            with self.subTest(file=path.name):
                self.assertNotIn("SSRVPN.zip", content)

        release_workflow = active_release_files[1].read_text(encoding="utf-8")
        self.assertIn("SSRVPN_Setup.exe", release_workflow)

        promotion = (
            ROOT / "scripts" / "promote-oss-public-channel.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("retired_files=(", promotion)
        self.assertIn("SSRVPN.zip SSRVPN.zip.sha256", promotion)
        self.assertIn('ossutil_bin\" rm', promotion)

        release_verifier = (
            ROOT / "scripts" / "check-release-assets.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("SSRVPN_ALLOW_RETIRED_WINDOWS_ZIP", release_verifier)
        self.assertIn(
            'allowed_retired = {"SSRVPN.zip", "SSRVPN.zip.sha256"}',
            release_verifier,
        )

        for removed in (
            "SSRVPN_Windows/PORTABLE_README.txt",
            "SSRVPN_Windows/build_release.bat",
        ):
            self.assertFalse((ROOT / removed).exists(), removed)


if __name__ == "__main__":
    unittest.main()
