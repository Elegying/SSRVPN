import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class FreeDesktopDistributionTest(unittest.TestCase):
    def test_macos_release_uses_minimal_runtime_entitlements(self) -> None:
        path = ROOT / "SSRVPN_MacOS" / "macos" / "Runner" / "Release.entitlements"
        with path.open("rb") as entitlement_file:
            entitlements = plistlib.load(entitlement_file)

        self.assertFalse(entitlements["com.apple.security.app-sandbox"])
        self.assertTrue(entitlements["com.apple.security.network.server"])
        self.assertTrue(entitlements["com.apple.security.network.client"])
        for debug_only in (
            "com.apple.security.cs.allow-jit",
            "com.apple.security.cs.allow-unsigned-executable-memory",
            "com.apple.security.cs.disable-library-validation",
        ):
            with self.subTest(entitlement=debug_only):
                self.assertNotIn(debug_only, entitlements)

        release_config = (
            ROOT
            / "SSRVPN_MacOS"
            / "macos"
            / "Runner"
            / "Configs"
            / "Release.xcconfig"
        ).read_text(encoding="utf-8")
        self.assertIn("CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO", release_config)

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
        windows_pubspec = (ROOT / "SSRVPN_Windows" / "pubspec.yaml").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("绿色免安装版", windows_pubspec)
        self.assertIn("Windows 安装版", windows_pubspec)

        active_release_files = (
            ROOT / ".github" / "workflows" / "ci.yml",
            ROOT / ".github" / "workflows" / "release.yml",
            ROOT / ".github" / "workflows" / "maintenance.yml",
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
        self.assertIn("Windows portable distribution retired", promotion)
        self.assertIn("replacing it with a retirement marker", promotion)

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
