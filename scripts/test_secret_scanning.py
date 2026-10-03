import unittest
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GITLEAKS_ACTION = (
    "gitleaks/gitleaks-action@"
    "e0c47f4f8be36e29cdc102c57e68cb5cbf0e8d1e"
)


class SecretScanningTest(unittest.TestCase):
    def test_tls_guard_rejects_block_and_function_reference_bypasses(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture = Path(folder)
            (fixture / "scripts").mkdir()
            shutil.copy(ROOT / "scripts/check-secrets.sh", fixture / "scripts")
            source = fixture / "packages/ssrvpn_shared/lib/client.dart"
            source.parent.mkdir(parents=True)
            subprocess.run(["git", "init", "-q", folder], check=True)
            source.write_text("final client = HttpClient();\n")
            subprocess.run(["git", "add", "."], cwd=fixture, check=True)
            for callback in (
                "(cert, host, port) => true",
                "(cert, host, port) { return true; }",
                "acceptEveryCertificate",
            ):
                source.write_text(f"client.badCertificateCallback = {callback};\n")
                result = subprocess.run(["bash", "scripts/check-secrets.sh"],
                                        cwd=fixture, capture_output=True, text=True)
                with self.subTest(callback=callback):
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("forbidden TLS trust bypass", result.stdout)
            source.write_text("final client = HttpClient();\n")
            subprocess.run(["bash", "scripts/check-secrets.sh"], cwd=fixture,
                           check=True, capture_output=True)

    def test_gitleaks_extends_defaults_and_scopes_vpn_fixture_allowlist(self) -> None:
        config = (ROOT / ".gitleaks.toml").read_text(encoding="utf-8")

        self.assertIn("useDefault = true", config)
        self.assertIn('id = "vpn-subscription-uri"', config)
        self.assertIn("[[rules.allowlists]]", config)
        self.assertIn("(test|tests)", config)

    def test_ci_and_release_scan_full_history_with_pinned_action(self) -> None:
        for name in ("ci.yml", "release.yml"):
            workflow = (ROOT / ".github" / "workflows" / name).read_text(
                encoding="utf-8"
            )
            self.assertIn(GITLEAKS_ACTION, workflow)
            self.assertIn("fetch-depth: 0", workflow)
            self.assertIn(
                "GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}",
                workflow,
            )

        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("pull-requests: read", ci)


if __name__ == "__main__":
    unittest.main()
