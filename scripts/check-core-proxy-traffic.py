#!/usr/bin/env python3
"""Exercise real DIRECT/proxy short connections without changing system networking."""

import argparse
from contextlib import ExitStack
import http.client
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import select
import socket
import socketserver
import subprocess
import tempfile
import threading
import time


class Target(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'proxy-traffic-regression' * 4096
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


class ConnectProxy(socketserver.StreamRequestHandler):
    def handle(self):
        method, destination, _ = self.rfile.readline().decode().split()
        assert method == 'CONNECT'
        host, port = destination.rsplit(':', 1)
        assert host == '127.0.0.1'
        while self.rfile.readline() not in (b'\r\n', b'\n', b''):
            pass
        with socket.create_connection((host, int(port)), timeout=5) as remote:
            self.wfile.write(b'HTTP/1.1 200 Connection Established\r\n\r\n')
            self.wfile.flush()
            peers = [self.connection, remote]
            while True:
                ready, _, _ = select.select(peers, [], [], 10)
                if not ready:
                    return
                for source in ready:
                    data = source.recv(65536)
                    if not data:
                        return
                    (remote if source is self.connection else self.connection).sendall(data)


class ProxyServer(socketserver.ThreadingTCPServer):
    daemon_threads = True


def serve(stack, server):
    stack.enter_context(server)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    stack.callback(worker.join)
    stack.callback(server.shutdown)
    return server.server_address[1]


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


def request(port, path, authenticated=True):
    connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
    try:
        headers = {'Authorization': 'Bearer loopback-traffic-test'} if authenticated else {}
        connection.request('GET', path, headers=headers)
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


def run(core):
    with ExitStack() as stack:
        folder = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='ssrvpn-traffic-check-')))
        direct = serve(stack, ThreadingHTTPServer(('127.0.0.1', 0), Target))
        proxied = serve(stack, ThreadingHTTPServer(('127.0.0.1', 0), Target))
        proxy = serve(stack, ProxyServer(('127.0.0.1', 0), ConnectProxy))
        mixed, api = free_port(), free_port()
        while api == mixed:
            api = free_port()
        config = folder / 'config.yaml'
        config.write_text(f'''mixed-port: {mixed}
external-controller: 127.0.0.1:{api}
secret: loopback-traffic-test
allow-lan: false
mode: rule
log-level: warning
ipv6: false
find-process-mode: off
dns:
  enable: false
tun:
  enable: false
proxies:
  - name: LocalProxy
    type: http
    server: 127.0.0.1
    port: {proxy}
rules:
  - DST-PORT,{proxied},LocalProxy
  - MATCH,DIRECT
''')
        log = stack.enter_context((folder / 'core.log').open('w+'))
        process = subprocess.Popen([str(core), '-d', str(folder), '-f', str(config)], stdout=log, stderr=log)
        def stop():
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        stack.callback(stop)
        for _ in range(100):
            try:
                status, _ = request(api, '/ssrvpn/traffic')
                if status == 200:
                    break
            except OSError:
                pass
            if process.poll() is not None:
                log.seek(0)
                raise AssertionError(log.read())
            time.sleep(.1)
        else:
            raise AssertionError('core API did not start')
        assert request(api, '/ssrvpn/traffic', False)[0] == 401

        def sample():
            status, body = request(api, '/ssrvpn/traffic')
            assert status == 200
            value = json.loads(body)
            assert set(value) == {'upload', 'download', 'sessionGeneration', 'sampledAtMillis'}
            return value

        def transfer(port, count):
            for _ in range(count):
                status, body = request(mixed, f'http://127.0.0.1:{port}/payload', False)
                assert status == 200 and body == b'proxy-traffic-regression' * 4096, (status, len(body), body[:200])

        initial = sample()
        transfer(direct, 5)
        direct_only = sample()
        assert (direct_only['upload'], direct_only['download']) == (0, 0), direct_only
        # No sampling during these short-lived connections: closed traffic must persist.
        transfer(proxied, 10)
        after_proxy = sample()
        assert after_proxy['upload'] > 0 and after_proxy['download'] >= 10 * 24 * 4096, after_proxy
        transfer(direct, 5)
        after_direct = sample()
        assert (after_direct['upload'], after_direct['download']) == (after_proxy['upload'], after_proxy['download'])
        transfer(proxied, 2)
        final = sample()
        assert final['download'] > after_direct['download']
        assert final['sessionGeneration'] == initial['sessionGeneration']
        assert final['sampledAtMillis'] >= initial['sampledAtMillis']
        print(json.dumps({'result': 'passed', 'direct_requests': 10, 'proxy_requests': 12,
                          'proxy_totals': final}, sort_keys=True))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('core', type=Path)
    core = parser.parse_args().core.resolve()
    if core.suffix == '.gz':
        with tempfile.TemporaryDirectory(prefix='ssrvpn-core-check-') as directory:
            executable = Path(directory) / 'AtlasCore'
            executable.write_bytes(gzip.decompress(core.read_bytes()))
            executable.chmod(0o700)
            run(executable)
    else:
        run(core)
