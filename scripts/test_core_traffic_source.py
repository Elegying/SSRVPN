"""Exercise fail-closed contracts for the three-platform traffic extension."""

import importlib.util
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('core_traffic', ROOT / 'scripts/core-traffic-source.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
build_spec = importlib.util.spec_from_file_location('core_asset', ROOT / 'scripts/build-core-asset.py')
builder = importlib.util.module_from_spec(build_spec)
build_spec.loader.exec_module(builder)


class CoreTrafficSourceTests(unittest.TestCase):
    def test_toolchain_download_rejects_changed_and_oversized_archives(self):
        payload = b'pinned toolchain archive'
        record = {'size': len(payload), 'sha256': hashlib.sha256(payload).hexdigest()}
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'go.tar.gz'
            builder.verified_archive(io.BytesIO(payload), target, record)
            self.assertEqual(target.read_bytes(), payload)
            for bad in [b'x' * len(payload), payload[:-1], payload + b'x']:
                with self.assertRaises(ValueError):
                    builder.verified_archive(io.BytesIO(bad), target, record)

    def test_source_records_match_the_current_extension(self):
        module.verify()

    def test_wrong_source_identity_is_rejected_before_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(module.subprocess, 'check_output', return_value='wrong\n'), \
                    patch.object(module.subprocess, 'run') as run:
                with self.assertRaisesRegex(SystemExit, 'identity mismatch'):
                    module.apply('macos', Path(directory))
                run.assert_not_called()
                self.assertEqual(list(Path(directory).iterdir()), [])

    def test_existing_extension_is_not_overwritten(self):
        source = json.loads((module.BUNDLE / 'sources.json').read_text())['android']
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / next(iter(module.COPIES.values()))
            target.parent.mkdir(parents=True)
            target.write_text('keep existing content')
            with patch.object(module.subprocess, 'check_output', side_effect=[source['commit'], source['tree']]), \
                    patch.object(module.subprocess, 'run') as run:
                with self.assertRaisesRegex(SystemExit, 'already present'):
                    module.apply('android', Path(directory))
                self.assertEqual(run.call_count, 1)  # Only git apply --check.
                self.assertEqual(target.read_text(), 'keep existing content')

    def test_runtime_edits_change_digest_but_tests_do_not(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory)
            for name in module.RUNTIME_FILES:
                (bundle / name).write_bytes((module.BUNDLE / name).read_bytes())
            with patch.object(module, 'BUNDLE', bundle):
                before = module.digest()
                (bundle / 'proxy_traffic_test.go').write_text('test only')
                self.assertEqual(before, module.digest())
                (bundle / 'route.go').write_text('modified runtime')
                self.assertNotEqual(before, module.digest())

    def test_records_without_extension_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            record = Path(directory) / 'SSRVPN_Android/assets/libgojni-source.txt'
            record.parent.mkdir(parents=True)
            record.write_text('Library SHA256: unrelated\n')
            with patch.object(module, 'ROOT', Path(directory)):
                with self.assertRaisesRegex(SystemExit, 'Traffic extension SHA256'):
                    module.verify()


if __name__ == '__main__':
    unittest.main()
