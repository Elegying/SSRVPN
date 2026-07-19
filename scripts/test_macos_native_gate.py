from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class MacosNativeGateTest(unittest.TestCase):
    def read(self, relative_path: str) -> str:
        return (ROOT / relative_path).read_text(encoding="utf-8")

    def test_native_runner_executes_runner_tests_only_on_macos(self) -> None:
        runner = self.read("scripts/test-macos-native.sh")

        self.assertIn('[[ "$(uname -s)" != "Darwin" ]]', runner)
        self.assertIn("flutter build macos --debug --config-only --no-pub", runner)
        self.assertIn("xcodebuild test", runner)
        self.assertIn("-only-testing:RunnerTests", runner)
        self.assertIn("CODE_SIGNING_ALLOWED=NO", runner)

    def test_native_runner_is_wired_into_all_macos_quality_gates(self) -> None:
        verify_all = self.read("scripts/verify-all.sh")
        ci = self.read(".github/workflows/ci.yml")
        release = self.read(".github/workflows/release.yml")
        testing = self.read("docs/TESTING.md")

        self.assertIn('run_step "macOS native unit tests" scripts/test-macos-native.sh', verify_all)
        self.assertRegex(
            ci,
            r"(?s)name: macOS native unit tests.+?matrix\.directory == 'SSRVPN_MacOS'.+?"
            r"bash scripts/test-macos-native\.sh",
        )
        self.assertRegex(
            release,
            r"(?s)name: macOS native unit tests.+?bash scripts/test-macos-native\.sh",
        )
        self.assertIn("scripts/test-macos-native.sh", testing)

    def test_signal_ownership_gate_has_no_fail_open_default(self) -> None:
        app_delegate = self.read("SSRVPN_MacOS/macos/Runner/AppDelegate.swift")
        signature = re.search(
            r"func terminateConfirmedCoreProcess\((.*?)\n  \) -> Bool",
            app_delegate,
            flags=re.DOTALL,
        )

        self.assertIsNotNone(signature)
        parameters = signature.group(1)
        self.assertIn("canSignalProcess: (Int32, Int32) -> Bool,", parameters)
        self.assertNotRegex(
            parameters,
            r"canSignalProcess:\s*\(Int32, Int32\) -> Bool\s*=",
        )


if __name__ == "__main__":
    unittest.main()
