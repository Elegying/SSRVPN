#!/usr/bin/env python3
"""Check explicit HY2 egress on loopback without a real node or system proxy."""
import argparse
import gzip
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run(core, folder):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as node:
        node.bind(('127.0.0.1', 0))
        node.settimeout(0.3)
        with socket.socket() as reserve:
            reserve.bind(('127.0.0.1', 0))
            port = reserve.getsockname()[1]
        proxy = {'name': 'fixture', 'type': 'hysteria2', 'server': '127.0.0.1',
                 'port': node.getsockname()[1], 'password': 'synthetic',
                 'ssrvpn-egress': 'ipv4'}
        config = {'mixed-port': port, 'ipv6': True, 'log-level': 'info',
                  'proxies': [proxy], 'rules': ['MATCH,fixture']}
        path = folder / 'config.json'
        # Unknown fields are silently accepted upstream; a malformed value must
        # fail parsing, proving this core actually consumes the extension.
        proxy['ssrvpn-egress'] = 'not-a-policy'
        path.write_text(json.dumps(config))
        check = subprocess.run([str(core), '-d', str(folder), '-t', '-f', str(path)],
                               capture_output=True, text=True, timeout=15)
        assert check.returncode != 0 and 'ssrvpn-egress' in check.stdout + check.stderr, check
        proxy['ssrvpn-egress'] = 'ipv4'
        path.write_text(json.dumps(config))
        with (folder / 'core.log').open('w') as log:
            process = subprocess.Popen([str(core), '-d', str(folder), '-f', str(path)],
                                       stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 10
                while True:
                    try:
                        connection = socket.create_connection(('127.0.0.1', port), timeout=1)
                        connection.close()
                        break
                    except OSError:
                        assert process.poll() is None, (folder / 'core.log').read_text()
                        if time.monotonic() >= deadline:
                            raise AssertionError('proxy did not start')
                        time.sleep(0.05)
                started = time.monotonic()
                with socket.create_connection(('127.0.0.1', port), timeout=2) as connection:
                    connection.sendall(b'CONNECT [2001:db8::1]:443 HTTP/1.1\r\n'
                                       b'Host: [2001:db8::1]:443\r\n\r\n')
                    # The HTTP listener acknowledges CONNECT before dialing.
                    # Assert tunnel closure, not that optimistic status code.
                    response = b''
                    while b'\r\n\r\n' not in response:
                        chunk = connection.recv(4096)
                        assert chunk, response
                        response += chunk
                    assert response.split(b' ', 2)[1] == b'200', response
                    assert response.endswith(b'\r\n\r\n'), response
                    assert connection.recv(1) == b'', 'unsupported tunnel stayed open'
                assert time.monotonic() - started < 2, 'literal IPv6 did not fail promptly'
                try:
                    node.recvfrom(65535)
                except socket.timeout:
                    pass
                else:
                    raise AssertionError('unsupported IPv6 opened a node transport')
                # IPv4 still attempts this same proxy, rather than falling back
                # to DIRECT or disabling the whole node after the IPv6 failure.
                with socket.create_connection(('127.0.0.1', port), timeout=2) as connection:
                    connection.sendall(b'CONNECT 192.0.2.1:443 HTTP/1.1\r\n'
                                       b'Host: 192.0.2.1:443\r\n\r\n')
                    node.settimeout(3)
                    payload, _ = node.recvfrom(65535)
                    assert payload, 'IPv4 did not use the configured node'
                print('Explicit IPv4 egress: invalid option rejected; IPv6 fails locally; IPv4 still uses node.')
            finally:
                process.terminate()
                process.wait(timeout=10)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='ssrvpn-egress-') as directory:
        folder = Path(directory)
        core = args.core.resolve() if args.core else folder / 'core'
        if not args.core:
            core.write_bytes(gzip.decompress((ROOT / 'SSRVPN_MacOS/assets/AtlasCore.gz').read_bytes()))
            core.chmod(0o700)
        run(core, folder)
