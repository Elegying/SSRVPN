"""Exercise fail-closed contracts for the three-platform traffic extension."""

import importlib.util
import errno
import hashlib
import io
import json
from pathlib import Path
import random
import tempfile
import unittest
from unittest.mock import MagicMock, patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('core_traffic', ROOT / 'scripts/core-traffic-source.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
build_spec = importlib.util.spec_from_file_location('core_asset', ROOT / 'scripts/build-core-asset.py')
builder = importlib.util.module_from_spec(build_spec)
build_spec.loader.exec_module(builder)

probe_spec = importlib.util.spec_from_file_location('core_probe', ROOT / 'scripts/check-core-proxy-traffic.py')
probe = importlib.util.module_from_spec(probe_spec)
probe_spec.loader.exec_module(probe)


class CoreTrafficReadinessTests(unittest.TestCase):
    def test_live_version_requires_custom_identity(self):
        for value in ('v1.19.29-ssrvpn.1', '7031b756-ssrvpn.1'):
            with patch.object(probe, 'request', return_value=(200, json.dumps({'version': value}).encode())):
                probe.require_custom_version(1234)
        for status, payload in ((200, {'version': 'v1.19.29'}), (200, {}),
                                (200, {'version': None}), (200, []),
                                (401, {'version': 'v1.19.29-ssrvpn.1'})):
            with self.subTest(status=status, payload=payload), \
                    patch.object(probe, 'request', return_value=(status, json.dumps(payload).encode())), \
                    self.assertRaisesRegex(AssertionError, 'custom core version'):
                probe.require_custom_version(1234)

    def test_mixed_port_skips_udp_reservation_and_releases_probes(self):
        sockets = [MagicMock() for _ in range(4)]
        for item in sockets:
            item.__enter__.return_value = item
        sockets[0].getsockname.return_value = ('127.0.0.1', 61472)
        sockets[1].bind.side_effect = OSError(10013, 'reserved UDP port')
        sockets[2].getsockname.return_value = ('127.0.0.1', 61473)
        with patch.object(probe.socket, 'socket', side_effect=sockets):
            self.assertEqual(probe.free_port(), 61473)
        sockets[1].bind.assert_called_once_with(('127.0.0.1', 61472))
        sockets[3].bind.assert_called_once_with(('127.0.0.1', 61473))
        for item in sockets:
            item.__exit__.assert_called_once()

    def test_mixed_port_failure_is_bounded_and_preserves_other_errors(self):
        for code in (errno.EACCES, errno.EADDRINUSE, errno.EMFILE):
            with self.subTest(code=code):
                sock = MagicMock()
                sock.__enter__.return_value = sock
                sock.bind.side_effect = OSError(code, 'fixture bind failure')
                with patch.object(probe.socket, 'socket', return_value=sock):
                    if code == errno.EMFILE:
                        with self.assertRaises(OSError) as error:
                            probe.free_port()
                        self.assertEqual(error.exception.errno, code)
                        self.assertEqual(sock.bind.call_count, 1)
                    else:
                        with self.assertRaisesRegex(RuntimeError, '32 attempts'):
                            probe.free_port()
                        self.assertEqual(sock.bind.call_count, 32)

    def test_mixed_port_escapes_contiguous_udp_reservations(self):
        tcp_attempts, udp_attempts, sockets = [], [], []

        def socket_factory(*args):
            item = MagicMock()
            item.__enter__.return_value = item
            sockets.append(item)
            is_udp = len(args) > 1 and args[1] == probe.socket.SOCK_DGRAM
            bound_port = 0

            def bind(address):
                nonlocal bound_port
                port = address[1]
                if is_udp:
                    udp_attempts.append(port)
                    if 52000 <= port < 52100 or port == 40001:
                        raise OSError(errno.EACCES, 'reserved UDP range')
                else:
                    tcp_attempts.append(port)
                    if port == 40000:
                        raise OSError(errno.EADDRINUSE, 'busy TCP port')
                    # An OS allocator can repeatedly select TCP ports whose
                    # UDP counterparts are all reserved on Windows.
                    port = port or 52000 + tcp_attempts.count(0)
                bound_port = port

            item.bind.side_effect = bind
            item.getsockname.side_effect = lambda: ('127.0.0.1', bound_port)
            return item

        with patch.object(probe.socket, 'socket', side_effect=socket_factory), \
                patch.object(random.SystemRandom, 'sample', return_value=list(range(40000, 40031))):
            self.assertEqual(probe.free_port(), 40002)
        self.assertEqual(tcp_attempts, [0, 40000, 40001, 40002])
        self.assertEqual(udp_attempts, [52001, 40001, 40002])
        for item in sockets:
            item.__exit__.assert_called_once()

    def test_api_ready_does_not_skip_waiting_for_proxy_listener(self):
        process = MagicMock()
        process.poll.return_value = None
        with patch.object(probe, 'request', return_value=(200, b'')) as request, \
                patch.object(probe.socket, 'create_connection', side_effect=[ConnectionRefusedError(), MagicMock()]) as connect, \
                patch.object(probe.time, 'sleep'):
            probe.wait_for_core(process, io.StringIO(''), 1234, 5678)
        self.assertEqual(request.call_count, 2)
        self.assertEqual(connect.call_count, 2)
        connect.assert_called_with(('127.0.0.1', 5678), timeout=.2)

    def test_dead_process_and_timeout_keep_diagnostics(self):
        for exited in (None, 1):
            with self.subTest(exited=exited):
                process = MagicMock()
                process.poll.return_value = exited
                with patch.object(probe, 'request', side_effect=ConnectionRefusedError()), \
                        patch.object(probe.time, 'sleep'), \
                        self.assertRaisesRegex(AssertionError, 'startup failure'):
                    probe.wait_for_core(process, io.StringIO('startup failure'), 1234, 5678)


class CoreTrafficSourceTests(unittest.TestCase):
    def test_desktop_inline_checks_start_after_tun_commit_and_running(self):
        # The behavioural partition test lives in executor. Also protect its
        # integration point: an early Initial opens reusable, unbound sockets.
        for platform in ('macos', 'windows'):
            with self.subTest(platform=platform):
                source = (module.BUNDLE / (platform + '.patch')).read_text()
                executor = source.split('+++ b/hub/executor/executor.go', 1)[1]
                prepare = executor.index('ssrvpnStartupProviders(cfg.Providers, cfg.General.Tun.Enable)')
                commit = executor.index('+\t\tupdateTun(cfg.General)')
                running = executor.index('\ttunnel.OnRunning()')
                checks = executor.index('+\tloadProvider(deferredProviders)')
                self.assertLess(prepare, commit)
                self.assertLess(commit, running)
                self.assertLess(running, checks)

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
