"""Exercise the actual privileged workflow shell with a local fake GitHub CLI."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / '.github/workflows/cleanup-pr-cache.yml'


class PrCacheCleanupTest(unittest.TestCase):
    def run_cleanup(self, number='232', ids='11\n12', fail_list=False):
        script = textwrap.dedent(WORKFLOW.read_text().split('        run: |\n', 1)[1])
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            gh = path / 'gh'
            gh.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['CALL_LOG'], 'a') as stream:
    stream.write(json.dumps(sys.argv[1:]) + '\\n')
if 'GET' in sys.argv:
    if os.environ['FAIL_LIST'] == '1': sys.exit(1)
    print(os.environ['CACHE_IDS'])
''')
            gh.chmod(0o755)
            log = path / 'calls'
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ['PATH'],
                       PR_NUMBER=number, GH_REPO='owner/project', CACHE_IDS=ids,
                       FAIL_LIST='1' if fail_list else '0', CALL_LOG=str(log))
            result = subprocess.run(['bash', '-c', script], env=env,
                                    text=True, capture_output=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_exact_ref_pagination_and_delete_ids(self):
        result, calls = self.run_cleanup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ref=refs/pull/232/merge', calls[0])
        self.assertIn('--paginate', calls[0])
        self.assertIn('.actions_caches[] | select(.ref == env.PR_REF) | .id', calls[0])
        self.assertEqual(calls[1:], [
            ['api', '--method', 'DELETE', 'repos/owner/project/actions/caches/11'],
            ['api', '--method', 'DELETE', 'repos/owner/project/actions/caches/12'],
        ])

    def test_empty_cache_is_success_and_list_failure_does_not_delete(self):
        result, calls = self.run_cleanup(ids='')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)
        result, calls = self.run_cleanup(fail_list=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)

    def test_invalid_pr_or_cache_id_fails_before_mutation(self):
        for number in ('', '0', '../main', '232; echo bad'):
            with self.subTest(number=number):
                result, calls = self.run_cleanup(number=number)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])
        result, calls = self.run_cleanup(ids='../main')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)

    def test_privileged_job_never_checks_out_or_executes_pr_content(self):
        workflow = WORKFLOW.read_text()
        self.assertIn('pull_request_target:\n    types: [closed]', workflow)
        self.assertIn('permissions:\n  actions: write', workflow)
        self.assertNotIn('uses:', workflow)
        self.assertNotIn('head.ref', workflow)
        self.assertNotIn('head.sha', workflow)
        self.assertNotIn('${{', workflow.split('        run: |\n', 1)[1])


if __name__ == '__main__':
    unittest.main()
