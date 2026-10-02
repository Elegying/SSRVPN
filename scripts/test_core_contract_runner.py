"""Contract runner must fail closed on missing/skipped tests, including cache hits."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('core_contracts', ROOT / 'scripts/test-core-contracts.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class CoreContractRunnerTests(unittest.TestCase):
    def test_all_reports_remaining_platforms_and_still_exits_failure(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(
                runner, 'run', side_effect=[RuntimeError('toolchain [environment]'), None, None]) as run, \
                patch('builtins.print') as output:
            with self.assertRaisesRegex(SystemExit, 'Failed core platforms: macos'):
                runner.main(['all', '--report-dir', folder])
            self.assertEqual([call.args[0] for call in run.call_args_list],
                             ['macos', 'windows', 'android'])
            output.assert_called_once_with('macos: FAILED: toolchain [environment]', flush=True)

    def test_toolchain_failure_preserves_phase_and_error(self):
        for error, kind in ((urllib.error.URLError('DNS unavailable'), 'environment'),
                            (SystemExit('Pinned toolchain unavailable'), 'environment'),
                            (ValueError('Pinned Go version mismatch'), 'integrity'),
                            (RuntimeError('Unclassified setup error'), 'setup')):
            with self.subTest(error=type(error).__name__), tempfile.TemporaryDirectory() as folder:
                report_dir = Path(folder)
                with patch.object(runner.builder, 'find_go', side_effect=error):
                    with self.assertRaises(RuntimeError):
                        runner.run('macos', report_dir)
                report = json.loads((report_dir / 'macos.json').read_text())
                self.assertEqual(report['status'], 'failed')
                self.assertEqual(report['phase'], 'toolchain')
                self.assertEqual(report['failure_kind'], kind)
                self.assertEqual(report['error_type'], type(error).__name__)
                self.assertIn(str(error), report['error'])

    def test_source_identity_rejection_is_reported_and_does_not_run_tests(self):
        with tempfile.TemporaryDirectory() as folder, \
                patch.object(runner.builder, 'find_go', return_value='/pinned/go'), \
                patch.object(runner.subprocess, 'check_output', return_value='go version go1.26.5 host'), \
                patch.object(runner.subprocess, 'run') as process, \
                patch.object(runner.source, 'apply', side_effect=SystemExit('source identity mismatch')):
            with self.assertRaisesRegex(RuntimeError, 'source-verification'):
                runner.run('macos', Path(folder))
            report = json.loads((Path(folder) / 'macos.json').read_text())
            self.assertEqual(report['failure_kind'], 'integrity')
            self.assertEqual(report['error_type'], 'SystemExit')
            self.assertEqual(process.call_count, 2)  # Only clone and checkout.

    def test_test_failures_keep_events_stderr_and_do_not_reuse_stale_results(self):
        expected = {('package/a', 'TestA')}
        cases = [('assertion', 'contract-failure'), ('build', 'execution'),
                 ('missing', 'contract-incomplete'), ('passed', None)]
        for mode, kind in cases:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                report_dir = Path(folder)
                log = report_dir / 'macos.jsonl'
                log.write_text(json.dumps({'Action': 'fail', 'Package': 'stale', 'Test': 'TestOld'}))

                def execute(command, **kwargs):
                    if command[0] == 'git':
                        return
                    kwargs['stderr'].write('compiler or assertion diagnostic\n')
                    if mode in ('assertion', 'passed'):
                        kwargs['stdout'].write(json.dumps({
                            'Action': 'fail' if mode == 'assertion' else 'pass',
                            'Package': 'package/a', 'Test': 'TestA'}) + '\n')
                    if mode in ('assertion', 'build'):
                        raise subprocess.CalledProcessError(1, command)

                with patch.object(runner.builder, 'find_go', return_value='/pinned/go'), \
                        patch.object(runner.subprocess, 'check_output', return_value='go version go1.26.5 host'), \
                        patch.object(runner.subprocess, 'run', side_effect=execute), \
                        patch.object(runner.source, 'apply'), \
                        patch.object(runner, 'contracts', return_value=expected), \
                        patch('builtins.print'):
                    if mode == 'passed':
                        runner.run('macos', report_dir)
                    else:
                        with self.assertRaises(RuntimeError):
                            runner.run('macos', report_dir)
                report = json.loads((report_dir / 'macos.json').read_text())
                self.assertEqual(report['failure_kind'], kind)
                self.assertEqual(report['status'], 'passed' if mode == 'passed' else 'failed')
                self.assertNotIn('TestOld', log.read_text())
                self.assertIn('diagnostic', (report_dir / 'macos.stderr.log').read_text())
                if mode == 'assertion':
                    self.assertEqual(report['failed_tests'], [['package/a', 'TestA']])

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
            for rejected in ({'Action': 'fail', 'Package': 'package/a'},
                             {'Action': 'skip', 'Package': 'package/a', 'Test': 'TestA'},
                             {'Action': 'fail', 'Package': 'package/a', 'Test': 'TestA/subtest'}):
                log.write_text('\n'.join(map(json.dumps, events + [rejected])))
                with self.subTest(rejected=rejected), self.assertRaises(ValueError):
                    runner.verify_events(log, expected)
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
