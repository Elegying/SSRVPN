import importlib.util
from pathlib import Path
import socket
import socketserver
import threading
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    'protocols', Path(__file__).with_name('check-core-dual-stack-protocols.py'))
protocols = importlib.util.module_from_spec(spec)
spec.loader.exec_module(protocols)


class UdpDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.trace = protocols.UdpTrace()
        self.patch = mock.patch.object(protocols, 'UDP_TRACE', self.trace)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def test_echo_records_real_received_and_sent_bytes(self):
        server = socketserver.ThreadingUDPServer(('127.0.0.1', 0), protocols.Echo)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            client.settimeout(2)
            client.sendto(b'probe-unique', server.server_address)
            reply, _ = client.recvfrom(4096)
        self.assertEqual(reply, b'4probe-unique')
        server.shutdown()
        server.server_close()  # Join echo handlers before reading their counters.
        snapshot = self.trace.snapshot()
        self.assertEqual(snapshot['counts'], {'echo_received': 1, 'echo_sent': 1})
        self.assertEqual([e['bytes'] for e in snapshot['timeline']], [12, 13])
        self.assertEqual({e['probe'] for e in snapshot['timeline']}, {'probe-unique'})

    def test_timeout_preserves_one_send_and_no_retry_or_receive(self):
        control = mock.MagicMock()
        control.__enter__.return_value = control
        stream = mock.MagicMock()
        stream.__enter__.return_value = stream
        stream.read.side_effect = [b'\x05\x00', b'\x05\x00\x00\x01', bytes(4), b'\x12\x34']
        control.makefile.return_value = stream
        datagram = mock.MagicMock()
        datagram.__enter__.return_value = datagram
        datagram.sendto.return_value = 100
        datagram.recvfrom.side_effect = TimeoutError('probe timeout')
        with mock.patch.object(protocols.socket, 'create_connection', return_value=control), \
             mock.patch.object(protocols.socket, 'socket', return_value=datagram):
            with self.assertRaises(TimeoutError):
                protocols.check_udp(18080, 18081, 'ss-test')
        snapshot = self.trace.snapshot()
        self.assertEqual(snapshot['counts'], {'client_sent': 1, 'client_timeout': 1})
        self.assertEqual(datagram.sendto.call_count, 1)
        datagram.settimeout.assert_called_once_with(5)
        self.assertEqual(len({e['probe'] for e in snapshot['timeline']}), 1)
        self.assertLessEqual(snapshot['timeline'][0]['elapsed_ms'], snapshot['timeline'][1]['elapsed_ms'])

    def test_timeline_is_bounded_but_counts_are_complete(self):
        for i in range(100):
            self.trace.record('client_sent', f'probe-{i}'.encode())
        snapshot = self.trace.snapshot()
        self.assertEqual(snapshot['counts']['client_sent'], 100)
        self.assertEqual(len(snapshot['timeline']), 64)
        self.assertEqual(snapshot['timeline'][-1]['probe'], 'probe-99')


if __name__ == '__main__':
    unittest.main()
