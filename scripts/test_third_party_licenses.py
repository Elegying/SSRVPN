#!/usr/bin/env python3
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ThirdPartyLicenseDistributionTest(unittest.TestCase):
    def test_notice_records_every_bundled_gpl_component(self) -> None:
        notice = (ROOT / "third_party/THIRD_PARTY_NOTICES.md").read_text(
            encoding="utf-8"
        )
        gpl = (ROOT / "third_party/licenses/GPL-3.0.txt").read_text(
            encoding="utf-8"
        )
        mit = (ROOT / "third_party/licenses/SSRVPN-MIT.txt").read_text(
            encoding="utf-8"
        )

        for required in (
            "MetaCubeX/mihomo",
            "v1.19.27",
            "v1.19.29",
            "zeyugao/mihomo",
            "7031b7569831677a8d89ad8a8a3347db116ba1a8",
            "MetaCubeX/meta-rules-dat",
            "GPL-3.0",
            "scripts/build-android-core.sh",
            "SSRVPN_Android/native/bridge/bridge.go",
        ):
            self.assertIn(required, notice)
        self.assertIn("GNU GENERAL PUBLIC LICENSE", gpl)
        self.assertIn("Version 3, 29 June 2007", gpl)
        self.assertEqual(mit, (ROOT / "LICENSE").read_text(encoding="utf-8"))

    def test_android_build_packages_notice_and_license(self) -> None:
        gradle = (
            ROOT / "SSRVPN_Android/android/app/build.gradle.kts"
        ).read_text(encoding="utf-8")
        smoke = (ROOT / "scripts/smoke-release-artifacts.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn('rootProject.file("../../third_party")', gradle)
        self.assertIn('assets/THIRD_PARTY_NOTICES.md', smoke)
        self.assertIn('assets/licenses/GPL-3.0.txt', smoke)
        self.assertIn('assets/licenses/SSRVPN-MIT.txt', smoke)

    def test_macos_package_and_smoke_require_license_materials(self) -> None:
        package = (ROOT / "SSRVPN_MacOS/tool/package_macos.sh").read_text(
            encoding="utf-8"
        )
        smoke = (ROOT / "scripts/smoke-release-artifacts.sh").read_text(
            encoding="utf-8"
        )
        workflow = (ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn('THIRD_PARTY_SOURCE="$PROJECT_ROOT/../third_party"', package)
        for source in (package, smoke, workflow):
            self.assertIn(
                "Contents/Resources/third_party/THIRD_PARTY_NOTICES.md",
                source,
            )
            self.assertIn(
                "Contents/Resources/third_party/licenses/GPL-3.0.txt",
                source,
            )
            self.assertIn(
                "Contents/Resources/third_party/licenses/SSRVPN-MIT.txt",
                source,
            )

    def test_windows_payload_and_installed_package_require_license_materials(self) -> None:
        package = (ROOT / "SSRVPN_Windows/tool/package_windows.ps1").read_text(
            encoding="utf-8"
        )
        smoke = (ROOT / "scripts/test_windows_installer_package.ps1").read_text(
            encoding="utf-8"
        )

        for required in (
            "third_party\\THIRD_PARTY_NOTICES.md",
            "third_party\\licenses\\GPL-3.0.txt",
            "third_party\\licenses\\SSRVPN-MIT.txt",
        ):
            self.assertIn(required, package)
            self.assertIn(required, smoke)

        provenance = "third_party\\MICROSOFT_RUNTIME_PROVENANCE.txt"
        self.assertIn(provenance, package)
        self.assertIn(provenance, smoke)

    def test_windows_microsoft_runtime_notice_links_official_terms(self) -> None:
        notice = (ROOT / "third_party/THIRD_PARTY_NOTICES.md").read_text(
            encoding="utf-8"
        )

        for required in (
            "Microsoft Visual C++ Runtime and D3DCompiler_47",
            "https://visualstudio.microsoft.com/license-terms/",
            "https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution",
            "https://learn.microsoft.com/en-us/windows/win32/directx-sdk--august-2009-",
            "MICROSOFT_RUNTIME_PROVENANCE.txt",
            "VisualStudioRedist",
            "WindowsKitsRedist",
        ):
            self.assertIn(required, notice)

    def test_public_copy_describes_mixed_license_distribution(self) -> None:
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        android_readme = (ROOT / "SSRVPN_Android/README.md").read_text(
            encoding="utf-8"
        )
        about = (
            ROOT / "packages/ssrvpn_shared/lib/widgets/ssrvpn_about_dialog.dart"
        ).read_text(encoding="utf-8")

        self.assertIn("自有代码采用", readme)
        self.assertIn("third_party/THIRD_PARTY_NOTICES.md", readme)
        self.assertIn("自有代码采用", android_readme)
        self.assertIn("../LICENSE", android_readme)
        self.assertIn("../third_party/THIRD_PARTY_NOTICES.md", android_readme)
        self.assertIn("第三方许可与对应源码", about)
        self.assertIn("/tree/v${AppConstants.appVersion}/third_party", about)

    def test_geoip_notice_points_to_commit_pinned_source_record(self) -> None:
        source = (ROOT / "docs/GEOIP_SOURCE.txt").read_text(encoding="utf-8")
        notice = (ROOT / "third_party/THIRD_PARTY_NOTICES.md").read_text(
            encoding="utf-8"
        )
        commit_match = re.search(
            r"^Release tag commit SHA: ([0-9a-f]{40})$",
            source,
            flags=re.MULTILINE,
        )
        self.assertIsNotNone(commit_match)
        assert commit_match is not None
        commit = commit_match.group(1)
        self.assertIn(
            "Immutable source archive: https://github.com/MetaCubeX/"
            f"meta-rules-dat/archive/{commit}.tar.gz",
            source,
        )
        self.assertIn(
            "Exact source commit and immutable source archive record: "
            "`docs/GEOIP_SOURCE.txt`",
            notice,
        )

    def test_privacy_copy_lists_primary_network_requests(self) -> None:
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        self.assertIn("应用主要会为", readme)
        self.assertIn("内置基线及受审查通道的路由规则刷新", readme)
        self.assertIn("DNS 解析", readme)


if __name__ == "__main__":
    unittest.main()
