"""Failure diagnostics for the isolated loopback traffic fixture."""

from contextlib import ExitStack, redirect_stderr
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    'core_proxy_traffic', Path(__file__).with_name('check-core-proxy-traffic.py'))
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class CoreLogDiagnosticsTest(unittest.TestCase):
    def diagnostic(self, content, error=None):
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'core.log'
            if content is not None:
                path.write_bytes(content)
            with redirect_stderr(output):
                if error is None:
                    with CHECK.report_core_failure(path):
                        pass
                else:
                    with self.assertRaises(type(error)) as raised:
                        with CHECK.report_core_failure(path):
                            raise error
                    self.assertIs(raised.exception, error)
        return output.getvalue()

    def test_success_is_silent(self):
        self.assertEqual(self.diagnostic(b'not printed'), '')

    def test_failure_prints_log_and_preserves_exception(self):
        output = self.diagnostic(b'dial tcp: connection refused\n', AssertionError('502'))
        self.assertIn('core.log | dial tcp: connection refused', output)

    def test_missing_log_preserves_exception(self):
        self.assertEqual(self.diagnostic(None, RuntimeError('original')), '')

    def test_invalid_utf8_does_not_hide_original_error(self):
        self.assertIn('\ufffd', self.diagnostic(b'bad\xff', AssertionError('original')))

    def test_output_is_bounded_tail(self):
        output = self.diagnostic(b'old marker\n' + b'x' * 70000 + b'\nlast marker', AssertionError())
        self.assertNotIn('old marker', output)
        self.assertIn('last marker', output)
        self.assertLess(len(output), 66000)

    def test_workflow_commands_are_prefixed(self):
        output = self.diagnostic(b'::error::synthetic\n', AssertionError())
        self.assertIn('core.log | ::error::synthetic', output)
        self.assertFalse(any(line.startswith('::') for line in output.splitlines()))

    def test_stderr_failure_preserves_exception(self):
        error = AssertionError('original')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'core.log'
            path.write_bytes(b'log')
            with patch('builtins.print', side_effect=OSError('closed pipe')):
                with self.assertRaises(AssertionError) as raised:
                    with CHECK.report_core_failure(path):
                        raise error
            self.assertIs(raised.exception, error)

    def test_run_failure_reports_after_stop_before_cleanup(self):
        output = io.StringIO()
        paths = []

        class Process:
            def __init__(self, _args, stdout, stderr):
                self.path = Path(stdout.name)
                paths.append(self.path)
                self.path.write_bytes(b'initial\n')

            def terminate(self):
                with self.path.open('ab') as log:
                    log.write(b'core stopped\n')

            def wait(self, timeout):
                return 0

        sample = {'upload': 0, 'download': 0, 'sessionGeneration': 1,
                  'sampledAtMillis': 1, 'ipv6TargetFailures': 0,
                  'ipv6LastFailureAgoMillis': 0}
        responses = [(401, b''), (200, CHECK.json.dumps(sample).encode()), (502, b'')]
        with ExitStack() as stack:
            stack.enter_context(patch.object(CHECK.subprocess, 'Popen', Process))
            stack.enter_context(patch.object(CHECK, 'wait_for_core'))
            stack.enter_context(patch.object(CHECK, 'require_custom_version'))
            stack.enter_context(patch.object(CHECK, 'request', side_effect=responses))
            stack.enter_context(redirect_stderr(output))
            with self.assertRaises(AssertionError) as raised:
                CHECK.run(Path('synthetic-core'))
        self.assertEqual(raised.exception.args, ((502, 0, b''),))
        self.assertIn('core.log | core stopped', output.getvalue())
        self.assertFalse(paths[0].parent.exists())


if __name__ == '__main__':
    unittest.main()
