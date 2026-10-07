import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/prepare-private-defines.py"
spec = importlib.util.spec_from_file_location("private_defines", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PrivateDefinesTest(unittest.TestCase):
    def test_preserves_other_settings_and_rejects_invalid_input(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / 'config').mkdir()
            base = {'SSRVPN_USAGE_PROVIDERS': '[]', 'SSRVPN_NODE_EGRESS': '[1]'}
            (root / 'config/ssrvpn-usage-defines.json').write_text(json.dumps(base))
            source = json.dumps([{'id': 'fixture'}])
            target = module.prepare(source, root)
            self.assertEqual(json.loads(target.read_text()),
                             {**base, 'SSRVPN_USAGE_PROVIDERS': source})
            if os.name != 'nt':
                self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            before = target.read_bytes()
            for invalid in ['', '[]', '{}', 'null', 'private-sentinel']:
                with self.assertRaises(ValueError):
                    module.prepare(invalid, root)
                self.assertEqual(target.read_bytes(), before)
            self.assertFalse(list(target.parent.glob('.defines-*')))

    def test_failure_does_not_print_input(self):
        result = subprocess.run([sys.executable, str(SCRIPT)],
                                env={**os.environ, 'SSRVPN_USAGE_PROVIDERS': 'private-sentinel'},
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('private-sentinel', result.stdout + result.stderr)

    def test_public_configuration_has_no_private_providers(self):
        config = json.loads((ROOT / 'config/ssrvpn-usage-defines.json').read_text())
        self.assertEqual(json.loads(config['SSRVPN_USAGE_PROVIDERS']), [])
        self.assertIn('/config/ssrvpn-private-defines.json', (ROOT / '.gitignore').read_text())
