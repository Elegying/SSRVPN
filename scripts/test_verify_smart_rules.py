"""Exercise the real bundled signature verifier on the host platform."""

from pathlib import Path
import shutil
import subprocess
import sys
import unittest


class BundledRuleSignatureTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which('openssl'), 'OpenSSL is required')
    def test_bundled_signature_verifies_on_host(self):
        root = Path(__file__).resolve().parents[1]
        result = subprocess.run(
            [sys.executable, str(root / 'scripts/verify-smart-rules.py')],
            cwd=root, capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Smart-rule bundle verified:', result.stdout)


if __name__ == '__main__':
    unittest.main()
