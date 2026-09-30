"""Contract runner must fail closed on missing/skipped tests, including cache hits."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('core_contracts', ROOT / 'scripts/test-core-contracts.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class CoreContractRunnerTests(unittest.TestCase):
    def test_all_copied_contracts_are_required(self):
        expected = runner.contracts()
        packages = {package for package, _ in expected}
        self.assertEqual(len(packages), 9)
        for name in ('TestSSRVPNEgressPolicy', 'TestSSRVPNDualStackConfigVersionMatrix',
                     'TestProxyTrafficConcurrentWrites', 'TestSSRVPNCoreVersion'):
            self.assertTrue(any(test == name for _, test in expected), name)

    def test_only_an_executed_passing_parent_test_satisfies_contract(self):
        expected = {('package/a', 'TestA'), ('package/b', 'TestB')}
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'events.jsonl'
            for action in ('skip', 'fail', 'run'):
                events = [{'Action': 'pass', 'Package': 'package/a', 'Test': 'TestA'},
                          {'Action': action, 'Package': 'package/b', 'Test': 'TestB'},
                          {'Action': 'pass', 'Package': 'package/b', 'Test': 'TestB/subtest'}]
                log.write_text('\n'.join(map(json.dumps, events)))
                with self.subTest(action=action), self.assertRaises(ValueError):
                    runner.verify_events(log, expected)
            events[1]['Action'] = 'pass'
            log.write_text('\n'.join(map(json.dumps, events)))
            self.assertEqual(runner.verify_events(log, expected), 2)
            log.write_text('')
            with self.assertRaises(ValueError):
                runner.verify_events(log, expected)

    def test_required_core_job_replays_before_binary_cache(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        job = workflow.split('\n  core-assets:\n', 1)[1].split('\n  macos-native:\n', 1)[0]
        step = job.split('name: Replay pinned three-platform core contracts', 1)[1].split('\n      - ', 1)[0]
        self.assertIn("if: needs.changes.outputs.platform_required == 'true'", step)
        self.assertIn('scripts/test-core-contracts.py all', step)
        self.assertNotIn('cache-hit', step)
        self.assertNotIn('continue-on-error', job)
        self.assertLess(job.index('scripts/test-core-contracts.py'), job.index('name: Cache verified core assets'))
        self.assertIn('always() &&', job)


if __name__ == '__main__':
    unittest.main()
