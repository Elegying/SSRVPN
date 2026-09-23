#!/usr/bin/env python3
"""Exercise production-parsed SS plugin/HY2 links against loopback servers.

No system proxy, routes, user settings or installed client are changed. The
client is the bundled core. A separate --server-core can provide newer inbound
implementations for the older Windows client's restls interoperability check.
Restls uses a public, normally verified TLS cover; application payloads stay on
loopback. This avoids adding a test certificate to the user's trusted roots.
"""
from contextlib import ExitStack
import argparse
import base64
import gzip
import hashlib
import http.client
import importlib.util
import json
from pathlib import Path
import select
import shutil
import socket
import socketserver
import ssl
import struct
import subprocess
import tempfile
import threading
import time
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('protocols', ROOT / 'scripts/check-core-dual-stack-protocols.py')
protocols = importlib.util.module_from_spec(spec)
spec.loader.exec_module(protocols)
traffic = protocols.traffic
PASSWORD = 'fixture:Pass@Word/2026'


class Target(traffic.Target):
    requests = 0

    def do_GET(self):
        type(self).requests += 1
        super().do_GET()


def launch_server(stack, core, folder, config, health):
    # Test servers may be upstream implementations without SSRVPN's traffic API.
    # The client below still uses the bundled-core readiness/identity checks.
    folder.mkdir()
    (folder / 'config.yaml').write_text(json.dumps(config))
    log = stack.enter_context((folder / 'core.log').open('w+'))
    process = subprocess.Popen([str(core), '-d', str(folder)], stdout=log, stderr=log)
    stack.callback(protocols.stop, process)
    for _ in range(100):
        try:
            status, _ = traffic.request(int(config['external-controller'].split(':')[-1]), '/version')
            if status == 200:
                with socket.create_connection(('127.0.0.1', config['mixed-port']), timeout=.2):
                    wait_ready(config['mixed-port'], health)
                    return process, log
        except OSError:
            pass
        if process.poll() is not None:
            break
        time.sleep(.1)
    log.flush()
    log.seek(0)
    raise AssertionError('test server did not start: ' + log.read())


def read_exact(stream, size):
    data = b''
    while len(data) < size:
        chunk = stream.read(size - len(data))
        if not chunk:
            raise EOFError('peer closed')
        data += chunk
    return data


class WebSocket(socketserver.StreamRequestHandler):
    """Small RFC6455 binary relay to a real Shadowsocks inbound."""
    def handle(self):
        remote = None
        try:
            self.connection.settimeout(5)
            first = self.rfile.readline().decode().split()
            if len(first) != 3 or first[:2] != ['GET', '/fixture']:
                return
            headers = {}
            while line := self.rfile.readline():
                if line in (b'\r\n', b'\n'):
                    break
                key, value = line.decode().split(':', 1)
                headers[key.lower()] = value.strip()
            if headers.get('host') != 'proxy.fixture':
                return
            accept = base64.b64encode(hashlib.sha1((headers['sec-websocket-key'] +
                '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
            self.wfile.write(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n'
                b'Connection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
            self.wfile.flush()
            remote = socket.create_connection(('127.0.0.1', self.server.backend), timeout=5)
            self.server.handshakes += 1

            def replies():
                try:
                    while payload := remote.recv(65536):
                        length = len(payload)
                        header = bytes([0x82, length]) if length < 126 else b'\x82\x7e' + struct.pack('!H', length) if length <= 65535 else b'\x82\x7f' + struct.pack('!Q', length)
                        self.connection.sendall(header + payload)
                except OSError:
                    pass

            worker = threading.Thread(target=replies, daemon=True)
            worker.start()
            try:
                while True:
                    header = read_exact(self.rfile, 2)
                    opcode, size = header[0] & 15, header[1] & 127
                    if size == 126:
                        size = struct.unpack('!H', read_exact(self.rfile, 2))[0]
                    elif size == 127:
                        size = struct.unpack('!Q', read_exact(self.rfile, 8))[0]
                    if size > 2**20 or not header[1] & 128 or opcode not in (0, 2, 8):
                        return
                    mask = read_exact(self.rfile, 4)
                    payload = read_exact(self.rfile, size)
                    if opcode == 8:
                        return
                    remote.sendall(bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload)))
            finally:
                remote.shutdown(socket.SHUT_RDWR)
                worker.join(timeout=5)
        except (OSError, EOFError, ValueError, KeyError):
            pass
        finally:
            if remote:
                remote.close()


class TLSWebSocket(WebSocket):
    def setup(self):
        self.request.settimeout(5)
        self.request = self.server.tls.wrap_socket(self.request, server_side=True)
        super().setup()


class TLSCover(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.request.settimeout(5)
            with self.server.tls.wrap_socket(self.request, server_side=True) as peer:
                peer.recv(4096)
                peer.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK')
        except (OSError, ssl.SSLError):
            pass


class HopRelay:
    """A UDP port pool, one stable upstream QUIC peer, no firewall rule."""
    def __init__(self, target):
        self.target = target
        # The pinned cores randomly select with replacement every >= 5 seconds.
        # With two ports, seven valid hops can all select the starting port
        # (1/128); that is not a broken hop timer. Sixteen ports make that
        # outcome negligible while packet counters still require real migration.
        self.sockets = [socket.socket(socket.AF_INET, socket.SOCK_DGRAM) for _ in range(17)]
        for peer in self.sockets:
            peer.bind(('127.0.0.1', 0))
        self.upstream = self.sockets[-1]
        self.ports = [peer.getsockname()[1] for peer in self.sockets[:-1]]
        self.counts = {port: 0 for port in self.ports}
        self.current = None
        self.error = None
        self.stopped = threading.Event()
        self.worker = threading.Thread(target=self.run, daemon=True)
        self.worker.start()

    def run(self):
        try:
            self.relay()
        except BaseException as error:
            self.error = error

    def relay(self):
        while not self.stopped.is_set():
            ready, _, _ = select.select(self.sockets, [], [], .1)
            for peer in ready:
                try:
                    payload, sender = peer.recvfrom(65535)
                except ConnectionResetError:
                    # Windows reports ICMP from a closed previous test client
                    # on the UDP listener. It must not kill the relay worker.
                    continue
                if peer is self.upstream:
                    if self.current:
                        self.current[0].sendto(payload, self.current[1])
                else:
                    self.counts[peer.getsockname()[1]] += 1
                    self.current = peer, sender
                    self.upstream.sendto(payload, ('127.0.0.1', self.target))

    def close(self):
        self.stopped.set()
        self.worker.join(timeout=3)
        for peer in self.sockets:
            peer.close()


def parse_links(dart, links):
    result = subprocess.run([dart, 'run', 'tool/parse_protocol_probe_links.dart'],
        cwd=ROOT / 'packages/ssrvpn_shared', input=json.dumps(links), text=True,
        capture_output=True, check=True, timeout=60)
    return json.loads(result.stdout)


def ss_link(port, plugin):
    credentials = base64.urlsafe_b64encode(('chacha20-ietf-poly1305:' + PASSWORD).encode()).decode().rstrip('=')
    return f'ss://{credentials}@127.0.0.1:{port}/?plugin={quote(plugin, safe="")}#fixture'


def client_config(proxy, cert, health):
    config = protocols.base_config()
    config.update(proxies=[proxy], rules=[f'DST-PORT,{health},DIRECT', 'MATCH,fixture'],
        tls={'custom-certifactes': [cert.read_text()]})
    return config


def transfer(port, target):
    status, body = traffic.request(port, f'http://127.0.0.1:{target}/payload', False)
    assert status == 200 and body == b'proxy-traffic-regression' * 4096, (status, len(body))


def wait_ready(port, health):
    # Mihomo binds its controller/mixed listeners before tunnel.OnRunning().
    # Probe a separate DIRECT-only fixture, so an early 502 cannot be mistaken
    # for either protocol incompatibility or successful password rejection.
    deadline = time.monotonic() + 10
    while True:
        try:
            transfer(port, health)
            return
        except (AssertionError, OSError, http.client.HTTPException):
            if time.monotonic() >= deadline:
                raise
            time.sleep(.1)


def udp_transfer(mixed, target):
    with socket.create_connection(('127.0.0.1', mixed), timeout=5) as control:
        control.sendall(b'\x05\x01\x00')
        with control.makefile('rb') as stream:
            assert read_exact(stream, 2) == b'\x05\x00'
            control.sendall(b'\x05\x03\x00\x01' + bytes(6))
            header = read_exact(stream, 4)
            assert header[:3] == b'\x05\x00\x00'
            read_exact(stream, 4 if header[3] == 1 else 16)
            relay = struct.unpack('!H', read_exact(stream, 2))[0]
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as peer:
                peer.settimeout(5)
                payload = b'hy2-port-hop-udp-payload'
                peer.sendto(b'\0\0\0\x01' + socket.inet_aton('127.0.0.1') + struct.pack('!H', target) + payload,
                    ('127.0.0.1', relay))
                reply, _ = peer.recvfrom(4096)
                offset = 10 if reply[3] == 1 else 22 if reply[3] == 4 else 7 + reply[4]
                assert reply[offset:] == b'4' + payload, reply


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', type=Path)
    parser.add_argument('--server-core', type=Path)
    parser.add_argument('--dart', default=shutil.which('dart'))
    parser.add_argument('--restls', action='store_true', help='Require a server core with a restls inbound')
    parser.add_argument('--restls-cover', default='www.microsoft.com:443')
    parser.add_argument('--case', action='append', dest='selected')
    args = parser.parse_args()
    if not args.dart:
        parser.error('Dart is required to exercise production link parsing')
    dart = Path(args.dart)
    if dart.suffix.lower() == '.bat':
        dart = dart.parent / 'cache/dart-sdk/bin/dart.exe'
    with ExitStack() as stack:
        folder = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='ssrvpn-imported-protocol-')))
        if args.core:
            core = args.core.resolve()
        else:
            core = folder / 'core'
            core.write_bytes(gzip.decompress((ROOT / 'SSRVPN_MacOS/assets/AtlasCore.gz').read_bytes()))
            core.chmod(0o700)
        server_core = args.server_core.resolve() if args.server_core else core
        target = traffic.serve(stack, traffic.ThreadingHTTPServer(('127.0.0.1', 0), Target))
        health = traffic.serve(stack, traffic.ThreadingHTTPServer(('127.0.0.1', 0), traffic.Target))
        udp = traffic.serve(stack, socketserver.ThreadingUDPServer(('127.0.0.1', 0), protocols.Echo))
        cert, key = folder / 'cert.pem', folder / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
            '-subj', '/CN=proxy.fixture', '-addext', 'subjectAltName=DNS:proxy.fixture',
            '-keyout', str(key), '-out', str(cert)], check=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()
        cover = traffic.ProxyServer(('127.0.0.1', 0), TLSCover)
        cover.tls = tls
        cover_port = traffic.serve(stack, cover)
        cases = ['obfs-http', 'obfs-tls', 'v2ray-plugin', 'gost-plugin', 'shadow-tls', 'kcptun']
        if args.restls:
            cases.append('restls')
        cases.append('hysteria2-port-hop')
        if args.selected:
            if set(args.selected) - set(cases):
                parser.error('unknown or disabled protocol case')
            cases = [case for case in cases if case in args.selected]
        for case in cases:
            with ExitStack() as run:
                entry = traffic.free_port()
                listener = {'name': 'fixture', 'type': 'shadowsocks', 'listen': '127.0.0.1',
                    'port': entry, 'cipher': 'chacha20-ietf-poly1305', 'password': PASSWORD, 'udp': True}
                server = protocols.base_config()
                server.update(listeners=[listener], rules=['MATCH,DIRECT'])
                websocket = None
                hop = None
                if case.startswith('obfs-'):
                    mode = case.removeprefix('obfs-')
                    listener['simple-obfs'] = {'enable': True, 'mode': mode}
                    link = ss_link(entry, f'simple-obfs;obfs={mode};obfs-host=proxy.fixture')
                elif case in ('v2ray-plugin', 'gost-plugin'):
                    websocket = traffic.ProxyServer(('127.0.0.1', 0), TLSWebSocket)
                    websocket.backend, websocket.tls, websocket.handshakes = entry, tls, 0
                    ws_port = traffic.serve(run, websocket)
                    link = ss_link(ws_port, f'{case};mode=websocket;host=proxy.fixture;path=/fixture;tls;skip-cert-verify=false;mux=false')
                elif case == 'shadow-tls':
                    listener['shadow-tls'] = {'enable': True, 'version': 3,
                        'users': [{'name': 'fixture', 'password': 'plugin-fixture'}],
                        'handshake': {'dest': f'127.0.0.1:{cover_port}'}, 'strict-mode': True}
                    link = ss_link(entry, 'shadow-tls;host=proxy.fixture;password=plugin-fixture;version=3;skip-cert-verify=false')
                elif case == 'kcptun':
                    listener['kcp-tun'] = {'enable': True, 'key': 'plugin-fixture', 'crypt': 'aes',
                        'mode': 'fast', 'nocomp': True, 'acknodelay': True}
                    link = ss_link(entry, 'kcptun;key=plugin-fixture;crypt=aes;mode=fast;nocomp=true;acknodelay=true;mtu=1350;smuxver=1')
                elif case == 'restls':
                    listener['res-tls'] = {'enable': True, 'dest': args.restls_cover,
                        'password': 'plugin-fixture'}
                    cover_host = args.restls_cover.rsplit(':', 1)[0]
                    link = ss_link(entry, f'restls;host={cover_host};password=plugin-fixture;version-hint=tls13')
                else:
                    listener.clear()
                    listener.update(name='fixture', type='hysteria2', listen='127.0.0.1', port=entry,
                        users={'fixture': PASSWORD}, certificate=cert.read_text(), **{'private-key': key.read_text()})
                    hop = HopRelay(entry)
                    run.callback(hop.close)
                    ports = ','.join(map(str, hop.ports))
                    link = f'hysteria2://{quote(PASSWORD, safe="")}@127.0.0.1:{entry}/?sni=proxy.fixture&pinSHA256={fingerprint}&mport={ports}&hop-interval=5#fixture'
                proxy, = parse_links(str(dart), [link])
                assert proxy and proxy['name'] == 'fixture', (case, 'production parser rejected fixture')
                _, server_log = launch_server(run, server_core, folder / f'{case}-server', server, health)
                client = client_config(proxy, cert, health)
                process, client_log = protocols.launch(run, core, folder / f'{case}-client', client)
                try:
                    traffic.require_custom_version(int(client['external-controller'].split(':')[-1]))
                    wait_ready(client['mixed-port'], health)
                    for _ in range(3):
                        transfer(client['mixed-port'], target)
                    if websocket:
                        assert websocket.handshakes > 0, 'WebSocket plugin was bypassed'
                    if hop:
                        deadline = time.monotonic() + 35
                        while sum(count > 0 for count in hop.counts.values()) < 2 and time.monotonic() < deadline:
                            time.sleep(.5)
                            transfer(client['mixed-port'], target)
                        assert sum(count > 0 for count in hop.counts.values()) >= 2, ('port hopping did not use distinct ports', hop.counts)
                        udp_transfer(client['mixed-port'], udp)
                    assert process.poll() is None, 'client core exited'
                    protocols.stop(process)
                    # A real authentication failure must never reach the target
                    # via an implicit DIRECT fallback, and must not kill the core.
                    if hop:
                        bad_link = link.replace(quote(PASSWORD, safe=''), 'wrong-password')
                    else:
                        good_auth = base64.urlsafe_b64encode(('chacha20-ietf-poly1305:' + PASSWORD).encode()).decode().rstrip('=')
                        bad_auth = base64.urlsafe_b64encode(b'chacha20-ietf-poly1305:wrong-password').decode().rstrip('=')
                        bad_link = link.replace(good_auth, bad_auth)
                    rejected, = parse_links(str(dart), [bad_link])
                    assert rejected, 'negative fixture should be syntactically valid'
                    negative = client_config(rejected, cert, health)
                    rejected_process, _ = protocols.launch(run, core, folder / f'{case}-bad-auth', negative)
                    wait_ready(negative['mixed-port'], health)
                    before = Target.requests
                    try:
                        status, _ = traffic.request(negative['mixed-port'], f'http://127.0.0.1:{target}/must-not-arrive', False)
                        assert status >= 400, (case, 'wrong password accepted', status)
                    except (OSError, http.client.HTTPException):
                        pass
                    assert Target.requests == before, (case, 'failed PROXY request reached target')
                    assert rejected_process.poll() is None, 'authentication failure killed core'
                    if hop:
                        assert hop.error is None and hop.worker.is_alive(), ('UDP relay failed', hop.error)
                    print(f'PASS: imported {case}, real handshake and payload' +
                        (', distinct UDP hop ports and TCP/UDP' if hop else '') +
                        ', wrong password rejected without DIRECT fallback', flush=True)
                except BaseException:
                    for log in (client_log, server_log):
                        log.flush()
                        log.seek(0)
                        print(log.read())
                    raise


if __name__ == '__main__':
    main()
