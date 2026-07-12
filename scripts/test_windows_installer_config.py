import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class WindowsInstallerConfigTest(unittest.TestCase):
    def test_installer_closes_ssrvpn_and_installs_per_user(self) -> None:
        script = (ROOT / "SSRVPN_Windows" / "installer" / "SSRVPN.iss").read_text(
            encoding="utf-8"
        )

        self.assertIn(r"DefaultDirName={localappdata}\Programs\SSRVPN", script)
        self.assertIn("PrivilegesRequired=lowest", script)
        self.assertIn("CloseApplications=force", script)
        self.assertIn("RestartApplications=no", script)
        self.assertNotIn("ChineseSimplified.isl", script)
        self.assertIn("ssrvpn_windows_app.exe", script)
        self.assertIn("ssrvpn_windows.exe", script)
        self.assertNotRegex(script, r"taskkill[^\n]+mihomo\.exe")
        run_entry = next(
            line for line in script.splitlines() if line.startswith('Filename: "{app}')
        )
        self.assertNotIn("postinstall", run_entry)
        self.assertNotIn("skipifsilent", run_entry)

    def test_release_pipeline_publishes_installer_and_checksum(self) -> None:
        release = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )
        required = {
            "tool\\build_installer.ps1",
            "SSRVPN_Windows/SSRVPN_Setup.exe",
            "SSRVPN_Windows/SSRVPN_Setup.exe.sha256",
        }
        for value in required:
            self.assertIn(value, release)

        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )
        for value in required:
            self.assertIn(value, ci)

    def test_windows_update_checker_selects_the_installer(self) -> None:
        service = (
            ROOT / "SSRVPN_Windows" / "lib" / "services" / "update_service.dart"
        ).read_text(encoding="utf-8")

        self.assertRegex(service, re.compile(r"assetExtension:\s*'\.exe'"))

    def test_portable_launcher_explains_complete_extraction(self) -> None:
        launcher = (
            ROOT
            / "SSRVPN_Windows"
            / "windows"
            / "runner"
            / "launcher_main.cpp"
        ).read_text(encoding="utf-8")

        self.assertIn("请完整解压 ZIP", launcher)
        self.assertIn("不能只复制 ssrvpn_windows.exe", launcher)


if __name__ == "__main__":
    unittest.main()
