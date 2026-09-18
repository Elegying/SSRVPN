#!/usr/bin/env python3
"""Real-core loopback dual-stack regression; never changes system routes/proxy."""
from contextlib import ExitStack
import argparse
import gzip
import http.client
import importlib.util
import json
from pathlib import Path
import select
import socket
import socketserver
import ssl
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('traffic', ROOT / 'scripts/check-core-proxy-traffic.py')
traffic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(traffic)


class DNS(socketserver.BaseRequestHandler):
    ipv4 = '192.0.2.10'
    ipv6 = '2001:db8::10'

    def handle(self):
        query, transport = self.request
        offset, labels = 12, []
        while query[offset]:
            size = query[offset]
            labels.append(query[offset + 1:offset + 1 + size].decode())
            offset += size + 1
        end = offset + 5
        kind = struct.unpack('!H', query[offset + 1:offset + 3])[0]
        host = '.'.join(labels)
        if (host == 'v4-slow-aaaa.fixture' and kind == 28) or (host == 'v6-slow-a.fixture' and kind == 1):
            return  # Simulate one DNS family timing out, not an empty answer.
        answer = b''
        if host == 'direct-mapped.fixture':
            address = socket.inet_pton(socket.AF_INET if kind == 1 else socket.AF_INET6,
                                      '127.0.0.1' if kind == 1 else '2001:db8::22') if kind in (1, 28) else b''
            if address:
                answer = b'\xc0\x0c' + struct.pack('!HHIH', kind, 1, 30, len(address)) + address
        if host == 'leak.fixture':
            address = socket.inet_pton(socket.AF_INET if kind == 1 else socket.AF_INET6,
                                      '127.0.0.1' if kind == 1 else '::1') if kind in (1, 28) else b''
            if address:
                answer = b'\xc0\x0c' + struct.pack('!HHIH', kind, 1, 30, len(address)) + address
        if host in {'dual.fixture', 'v6.fixture', 'v4-slow-aaaa.fixture', 'v6-slow-a.fixture'}:
            if kind == 1 and host in {'dual.fixture', 'v4-slow-aaaa.fixture'}:
                address = socket.inet_pton(socket.AF_INET, self.ipv4)
            elif kind == 28:
                address = socket.inet_pton(socket.AF_INET6, self.ipv6)
            else:
                address = b''
            if address:
                answer = b'\xc0\x0c' + struct.pack('!HHIH', kind, 1, 30, len(address)) + address
        header = query[:2] + struct.pack('!HHHHH', 0x8180, 1, bool(answer), 0, 0)
        transport.sendto(header + query[12:end] + answer, self.client_address)


class Proxy(traffic.ConnectProxy):
    targets = []
    fail_ipv6 = False
    fail_ipv4 = False

    def handle(self):
        first = self.rfile.readline().decode()
        if not first:
            return
        method, destination, _ = first.split()
        assert method == 'CONNECT'
        host, port = destination.rsplit(':', 1)
        host = host.strip('[]')
        assert host in {'192.0.2.10', '2001:db8::10', 'v6.fixture', 'fallback.fixture', '127.0.0.1', '::1', 'leak.fixture'}, host
        self.targets.append(host)
        while self.rfile.readline() not in (b'\r\n', b'\n', b''):
            pass
        if host in {'127.0.0.1', '::1', 'leak.fixture'} or (self.fail_ipv6 and host in {'2001:db8::10', 'v6.fixture'}) or (self.fail_ipv4 and host == '192.0.2.10'):
            self.wfile.write(b'HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n')
            return
        with socket.create_connection(('127.0.0.1', int(port)), timeout=3) as remote:
            self.wfile.write(b'HTTP/1.1 200 Connection Established\r\n\r\n')
            self.wfile.flush()
            while True:
                ready, _, _ = select.select([self.connection, remote], [], [], 5)
                if not ready:
                    return
                for source in ready:
                    try:
                        data = source.recv(65536)
                    except ConnectionResetError:
                        return  # Expected when the TLS client rejects a certificate.
                    if not data:
                        return
                    (remote if source is self.connection else self.connection).sendall(data)


class UDPRelay(socketserver.BaseRequestHandler):
    targets = []

    def handle(self):
        data, transport = self.request
        kind = data[3]
        if kind == 1:
            host = socket.inet_ntop(socket.AF_INET, data[4:8])
        elif kind == 4:
            host = socket.inet_ntop(socket.AF_INET6, data[4:20])
        else:
            host = data[5:5 + data[4]].decode()
        self.targets.append(host)
        transport.sendto(data, self.client_address)


class SocksAssociation(socketserver.StreamRequestHandler):
    relay_port = 0

    def handle(self):
        version, count = self.rfile.read(2)
        assert version == 5
        self.rfile.read(count)
        self.wfile.write(b'\x05\x00')
        self.wfile.flush()
        header = self.rfile.read(4)
        if not header:
            return
        kind = header[3]
        length = {1: 4, 4: 16}.get(kind)
        if kind == 3:
            length = self.rfile.read(1)[0]
        self.rfile.read(length + 2)
        assert header[1] == 3, 'only UDP ASSOCIATE is expected'
        self.wfile.write(b'\x05\x00\x00\x01\x7f\x00\x00\x01' + struct.pack('!H', self.relay_port))
        self.wfile.flush()
        self.rfile.read(1)  # Association lifetime is bound to the TCP socket.


class DirectUDPEcho(socketserver.BaseRequestHandler):
    def handle(self):
        payload, transport = self.request
        transport.sendto(payload, self.client_address)


def check_udp(mixed, direct_port):
    with socket.create_connection(('127.0.0.1', mixed), timeout=5) as control:
        control.sendall(b'\x05\x01\x00')
        stream = control.makefile('rb')
        assert stream.read(2) == b'\x05\x00'
        control.sendall(b'\x05\x03\x00\x01' + bytes(6))
        header = stream.read(4)
        assert header[:3] == b'\x05\x00\x00'
        size = 4 if header[3] == 1 else 16
        address = stream.read(size)
        port = struct.unpack('!H', stream.read(2))[0]
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            client.settimeout(5)
            for host, expected in [('dual.fixture', '192.0.2.10'), ('v6.fixture', '2001:db8::10')]:
                UDPRelay.targets.clear()
                encoded = host.encode()
                packet = b'\x00\x00\x00\x03' + bytes([len(encoded)]) + encoded + struct.pack('!H', 8888) + b'dual-stack-udp'
                client.sendto(packet, ('127.0.0.1', port))
                reply, _ = client.recvfrom(4096)
                assert reply.endswith(b'dual-stack-udp') and UDPRelay.targets == [expected], UDPRelay.targets
        # Use a fresh source socket: native UDP associations keep the selected outbound.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as direct_client:
            direct_client.settimeout(5)
            # A real mapped AAAA enters the SOCKS/TUN-shared UDP pipeline.
            # The reply must retain the original IPv6 identity after a DIRECT
            # IPv4 socket carried the datagram; no custom NAT implementation.
            UDPRelay.targets.clear()
            original = socket.inet_pton(socket.AF_INET6, '2001:db8::22')
            header = b'\x00\x00\x00\x04' + original + struct.pack('!H', direct_port)
            direct_client.sendto(header + b'mapped-direct-udp', ('127.0.0.1', port))
            reply, _ = direct_client.recvfrom(4096)
            assert reply == header + b'mapped-direct-udp', 'DIRECT UDP reply mapping lost'
            assert not UDPRelay.targets, 'DIRECT packet entered a proxy'
        stream.close()


class IPv6HTTP(traffic.ThreadingHTTPServer):
    address_family = socket.AF_INET6


class LeakCanary(traffic.Target):
    requests = 0

    def do_GET(self):
        type(self).requests += 1
        super().do_GET()


def fake_dns_address(port, host, kind):
    question = b''.join(bytes([len(label)]) + label.encode() for label in host.split('.')) + b'\0'
    query = struct.pack('!HHHHHH', 0x5312, 0x100, 1, 0, 0, 0) + question + struct.pack('!HH', kind, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.settimeout(3)
        client.sendto(query, ('127.0.0.1', port))
        reply, _ = client.recvfrom(4096)
    assert struct.unpack('!H', reply[6:8])[0] == 1, 'Fake-IP DNS must return an answer'
    size = 4 if kind == 1 else 16
    return socket.inet_ntop(socket.AF_INET if kind == 1 else socket.AF_INET6, reply[-size:])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', type=Path, help='Audited local candidate executable; defaults to the packaged macOS core')
    args = parser.parse_args()
    with ExitStack() as stack:
        folder = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='ssrvpn-dual-stack-')))
        core = folder / 'core'
        core.write_bytes(args.core.read_bytes() if args.core else
                         gzip.decompress((ROOT / 'SSRVPN_MacOS/assets/AtlasCore.gz').read_bytes()))
        core.chmod(0o700)
        dns = traffic.serve(stack, socketserver.ThreadingUDPServer(('127.0.0.1', 0), DNS))
        proxy = traffic.serve(stack, traffic.ProxyServer(('127.0.0.1', 0), Proxy))
        SocksAssociation.relay_port = traffic.serve(stack, socketserver.ThreadingUDPServer(('127.0.0.1', 0), UDPRelay))
        socks_proxy = traffic.serve(stack, traffic.ProxyServer(('127.0.0.1', 0), SocksAssociation))
        target = traffic.serve(stack, traffic.ThreadingHTTPServer(('127.0.0.1', 0), traffic.Target))
        target6 = traffic.serve(stack, IPv6HTTP(('::1', 0), traffic.Target))
        canary = traffic.serve(stack, traffic.ThreadingHTTPServer(('127.0.0.1', 0), LeakCanary))
        canary6 = traffic.serve(stack, IPv6HTTP(('::1', 0), LeakCanary))
        direct_udp = traffic.serve(stack, socketserver.ThreadingUDPServer(('127.0.0.1', 0), DirectUDPEcho))
        mixed, api, core_dns = traffic.free_port(), traffic.free_port(), traffic.free_port()
        config = {
            'mixed-port': mixed, 'external-controller': f'127.0.0.1:{api}',
            'secret': 'loopback-traffic-test', 'ipv6': True, 'mode': 'rule',
            'dns': {'enable': True, 'ipv6': True, 'listen': f'127.0.0.1:{core_dns}', 'enhanced-mode': 'fake-ip',
                    'fake-ip-range': '198.18.0.1/16', 'fake-ip-range6': 'fdfe:dcba:9877::/64',
                    'fake-ip-filter': ['direct-mapped.fixture'],
                    'nameserver': [f'127.0.0.1:{dns}']},
            'proxies': [{'name': 'fixture', 'type': 'http', 'server': '127.0.0.1', 'port': proxy}, {'name': 'udp-fixture', 'type': 'socks5', 'server': '127.0.0.1', 'port': socks_proxy, 'udp': True}],
            'rules': ['DOMAIN,direct-mapped.fixture,DIRECT', 'DOMAIN,leak.fixture,fixture', f'AND,((IP-CIDR6,::1/128),(DST-PORT,{canary6})),fixture',
                      'NETWORK,udp,udp-fixture', 'IP-CIDR6,::1/128,DIRECT,no-resolve',
                      'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve', 'MATCH,fixture'],
        }
        (folder / 'config.yaml').write_text(json.dumps(config))
        with (folder / 'core.log').open('w+') as log:
            process = subprocess.Popen([str(core), '-d', str(folder)], stdout=log, stderr=log)
            try:
                traffic.wait_for_core(process, log, api, mixed)
                deadline = time.monotonic() + 10
                while traffic.request(mixed, f'http://127.0.0.1:{target}/ready', False)[0] != 200:
                    if time.monotonic() >= deadline:
                        raise AssertionError('routing did not become ready')
                    time.sleep(.05)
                for host, expected in [('dual.fixture', '192.0.2.10'), ('v6.fixture', '2001:db8::10'), ('fallback.fixture', 'fallback.fixture')]:
                    Proxy.targets.clear()
                    status, _ = traffic.request(mixed, f'http://{host}:{target}/payload', False)
                    assert status == 200 and Proxy.targets[0] == expected, (host, status, Proxy.targets)
                Proxy.targets.clear()
                assert traffic.request(mixed, f'http://[::1]:{target6}/payload', False)[0] == 200
                assert traffic.request(mixed, f'http://127.0.0.1:{target}/payload', False)[0] == 200
                assert not Proxy.targets, 'direct traffic reached proxy'

                # Exercise actual DNS responses and reverse mappings, not just
                # an emitted ipv6 flag. The original name must recover before
                # ULA/private DIRECT rules can classify a synthetic IPv6 target.
                for kind in (1, 28):
                    address = fake_dns_address(core_dns, 'dual.fixture', kind)
                    expected_prefix = '198.18.' if kind == 1 else 'fdfe:dcba:9877:'
                    assert address.startswith(expected_prefix), address
                    literal = address if kind == 1 else f'[{address}]'
                    Proxy.targets.clear()
                    assert traffic.request(mixed, f'http://{literal}:{target}/fake-mapping', False)[0] == 200
                    assert Proxy.targets and Proxy.targets[0] == '192.0.2.10', Proxy.targets

                # Both destinations really exist locally. A silent DIRECT
                # fallback would succeed and increment the canary, so a failed
                # request alone cannot falsely pass this leak check.
                before = LeakCanary.requests
                for destination in (f'leak.fixture:{canary}', f'[::1]:{canary6}'):
                    try:
                        status, _ = traffic.request(mixed, f'http://{destination}/must-not-leak', False)
                        assert status >= 400, (destination, status)
                    except (OSError, http.client.HTTPException):
                        pass
                assert LeakCanary.requests == before, 'PROXY failure leaked to a reachable DIRECT target'

                # The proxy sees the selected IP, but HTTPS still uses the
                # original hostname for SNI, certificate validation and Host.
                subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=dual.fixture', '-addext', 'subjectAltName=DNS:dual.fixture', '-keyout', str(folder / 'key.pem'), '-out', str(folder / 'cert.pem')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                tls_server = traffic.ThreadingHTTPServer(('127.0.0.1', 0), traffic.Target)
                server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                server_context.load_cert_chain(folder / 'cert.pem', folder / 'key.pem')
                names = []
                server_context.set_servername_callback(lambda _s, name, _c: names.append(name))
                tls_server.socket = server_context.wrap_socket(tls_server.socket, server_side=True)
                tls_port = traffic.serve(stack, tls_server)
                client_context = ssl.create_default_context(cafile=str(folder / 'cert.pem'))
                for name in ['dual.fixture', 'wrong.fixture']:
                    connection = http.client.HTTPConnection('127.0.0.1', mixed, timeout=5)
                    connection.set_tunnel('dual.fixture', tls_port)
                    connection.connect()
                    try:
                        connection.sock = client_context.wrap_socket(connection.sock, server_hostname=name)
                        assert name == 'dual.fixture', 'wrong certificate accepted'
                        connection.request('GET', '/', headers={'Host': 'dual.fixture'})
                        assert connection.getresponse().status == 200
                    except ssl.SSLCertVerificationError:
                        assert name == 'wrong.fixture'
                    finally:
                        connection.close()
                assert 'dual.fixture' in names

                mapped = fake_dns_address(core_dns, 'direct-mapped.fixture', 28)
                assert mapped == '2001:db8::22', mapped
                assert traffic.request(mixed, f'http://[{mapped}]:{target}/mapped-direct', False)[0] == 200
                check_udp(mixed, direct_udp)
                Proxy.targets.clear()
                Proxy.fail_ipv4 = True
                assert traffic.request(mixed, f'http://dual.fixture:{target}/fallback-v6', False)[0] == 200
                assert Proxy.targets[:2] == ['192.0.2.10', '2001:db8::10'], Proxy.targets
                Proxy.fail_ipv4 = False
                Proxy.fail_ipv6 = True
                Proxy.targets.clear()
                assert traffic.request(mixed, f'http://dual.fixture:{target}/ipv4-still-works', False)[0] == 200
                assert Proxy.targets == ['2001:db8::10', '192.0.2.10'], (
                    'successful IPv6 preference must be tried, then safely fall back within the proxy', Proxy.targets)
                connection = http.client.HTTPConnection('127.0.0.1', mixed, timeout=15)
                try:
                    connection.request('GET', f'http://v6.fixture:{target}/failure')
                    assert connection.getresponse().status >= 400
                except (OSError, http.client.HTTPException):
                    pass
                finally:
                    connection.close()
                status, body = traffic.request(api, '/ssrvpn/traffic')
                observation = json.loads(body)
                assert status == 200 and observation['ipv6TargetFailures'] > 0, observation
                assert traffic.request(mixed, f'http://127.0.0.1:{target}/still-running', False)[0] == 200
                print('PASS: TCP/UDP, actual-response family preference, IPv6-only, dual Fake-IP reverse mapping, no DIRECT payload leak, IPv4/IPv6 DIRECT, TLS/SNI, certificate rejection, surviving core')
            except BaseException:
                log.flush()
                log.seek(0)
                print(log.read())
                raise
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == '__main__':
    main()
