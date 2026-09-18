#!/usr/bin/env python3
"""Loopback-only SS/Trojan/AnyTLS dual-stack data-path regression."""
from contextlib import ExitStack
import argparse
import http.client
import itertools
import gzip
import importlib.util
import json
from pathlib import Path
import socket
import socketserver
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('dual', ROOT / 'scripts/check-core-dual-stack.py')
dual = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dual)
traffic = dual.traffic


class DNS(dual.DNS):
    ipv4 = '127.0.0.1'
    ipv6 = '::1'


class Target(traffic.Target):
    families = []

    def do_GET(self):
        self.families.append(self.server.address_family)
        super().do_GET()


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        payload, transport = self.request
        family = b'4' if self.server.address_family == socket.AF_INET else b'6'
        transport.sendto(family + payload, self.client_address)


class UDP6(socketserver.ThreadingUDPServer):
    address_family = socket.AF_INET6


def check_udp(mixed, target):
    with socket.create_connection(('127.0.0.1', mixed), timeout=5) as control:
        control.sendall(b'\x05\x01\x00')
        with control.makefile('rb') as stream:
            assert stream.read(2) == b'\x05\x00'
            control.sendall(b'\x05\x03\x00\x01' + bytes(6))
            header = stream.read(4)
            assert header[:3] == b'\x05\x00\x00'
            stream.read(4 if header[3] == 1 else 16)
            port = struct.unpack('!H', stream.read(2))[0]
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
                client.settimeout(5)
                # Reuse one association and source port, including a return to
                # the first target, to exercise the live UDP NAT mapping.
                for host, family in [('dual.fixture', b'4'), ('v6.fixture', b'6'), ('dual.fixture', b'4')]:
                    encoded = host.encode()
                    payload = b'protocol-udp-' + encoded
                    client.sendto(b'\x00\x00\x00\x03' + bytes([len(encoded)]) + encoded + struct.pack('!H', target) + payload, ('127.0.0.1', port))
                    reply, _ = client.recvfrom(4096)
                    kind = reply[3]
                    offset = 10 if kind == 1 else 22 if kind == 4 else 7 + reply[4]
                    assert reply[offset:] == family + payload, reply


def stop(process):
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def launch(stack, core, folder, config):
    folder.mkdir()
    (folder / 'config.yaml').write_text(json.dumps(config))
    log = stack.enter_context((folder / 'core.log').open('w+'))
    process = subprocess.Popen([str(core), '-d', str(folder)], stdout=log, stderr=log)
    stack.callback(stop, process)
    traffic.wait_for_core(process, log, int(config['external-controller'].split(':')[-1]), config['mixed-port'])
    return process, log


def base_config():
    return {'mixed-port': traffic.free_port(),
            'external-controller': f'127.0.0.1:{traffic.free_port()}',
            'secret': 'loopback-traffic-test', 'ipv6': True, 'mode': 'rule'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', type=Path)
    args = parser.parse_args()
    with ExitStack() as stack:
        folder = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='ssrvpn-protocol-dual-')))
        core = folder / 'core'
        core.write_bytes(args.core.read_bytes() if args.core else gzip.decompress((ROOT / 'SSRVPN_MacOS/assets/AtlasCore.gz').read_bytes()))
        core.chmod(0o700)
        dns = traffic.serve(stack, socketserver.ThreadingUDPServer(('127.0.0.1', 0), DNS))
        target4 = traffic.ThreadingHTTPServer(('127.0.0.1', 0), Target)
        target_port = traffic.serve(stack, target4)
        traffic.serve(stack, dual.IPv6HTTP(('::1', target_port), Target))
        udp_port = traffic.serve(stack, socketserver.ThreadingUDPServer(('127.0.0.1', 0), Echo))
        traffic.serve(stack, UDP6(('::1', udp_port), Echo))
        cert, key = folder / 'cert.pem', folder / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=proxy.fixture', '-addext', 'subjectAltName=DNS:proxy.fixture', '-keyout', str(key), '-out', str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for protocol, exit_family in itertools.product(['ss', 'trojan', 'anytls'], ['dual-stack', 'ipv4-only', 'ipv6-only']):
            ipv4_only = exit_family == 'ipv4-only'
            ipv6_only = exit_family == 'ipv6-only'
            case = f'{protocol}-{exit_family}'
            with ExitStack() as run:
                entry = traffic.free_port()
                listener = {'name': 'fixture', 'type': 'shadowsocks' if protocol == 'ss' else protocol, 'listen': '127.0.0.1', 'port': entry}
                proxy = {'name': 'fixture', 'type': protocol, 'server': '127.0.0.1', 'port': entry, 'password': 'local-test-password', 'udp': True}
                if protocol == 'ss':
                    listener.update(cipher='chacha20-ietf-poly1305', password=proxy['password'], udp=True)
                    proxy['cipher'] = listener['cipher']
                else:
                    listener.update(certificate=cert.read_text(), **{'private-key': key.read_text()})
                    listener['users'] = {'fixture': proxy['password']} if protocol == 'anytls' else [{'username': 'fixture', 'password': proxy['password']}]
                    proxy.update(sni='proxy.fixture', **{'skip-cert-verify': False})
                server = base_config()
                server.update(dns={'enable': True, 'ipv6': True, 'nameserver': [f'127.0.0.1:{dns}'], 'direct-nameserver': [f'127.0.0.1:{dns}']}, listeners=[listener])
                # Simulate node egress separately from its IPv4 loopback entrance.
                # The node resolves domains itself; reject unavailable literal
                # families and constrain its DIRECT dialer to the available one.
                unavailable = ['IP-CIDR6,::/0,REJECT,no-resolve'] if ipv4_only else ['IP-CIDR,0.0.0.0/0,REJECT,no-resolve'] if ipv6_only else []
                server['proxies'] = [{'name': 'egress', 'type': 'direct', 'ip-version': 'ipv4' if ipv4_only else 'ipv6' if ipv6_only else 'dual'}]
                server['rules'] = unavailable + ['MATCH,egress']
                _, server_log = launch(run, core, folder / f'{case}-server', server)
                client = base_config()
                client['tls'] = {'custom-certifactes': [cert.read_text()]}
                core_dns = traffic.free_port()
                client.update(dns={'enable': True, 'ipv6': True, 'listen': f'127.0.0.1:{core_dns}', 'enhanced-mode': 'fake-ip', 'fake-ip-range': '198.18.0.1/16', 'fake-ip-range6': 'fdfe:dcba:9877::/64', 'nameserver': [f'127.0.0.1:{dns}']}, proxies=[proxy], rules=['MATCH,fixture'])
                _, client_log = launch(run, core, folder / f'{case}-client', client)
                try:
                    deadline = time.monotonic() + 10
                    while traffic.request(client['mixed-port'], f'http://dual.fixture:{target_port}/ready', False)[0] != 200:
                        if time.monotonic() >= deadline:
                            raise AssertionError('protocol route did not become ready')
                        time.sleep(.05)
                    for host, family in [('dual.fixture', socket.AF_INET), ('v6.fixture', socket.AF_INET6), ('[::1]', socket.AF_INET6), ('v4-slow-aaaa.fixture', socket.AF_INET), ('v6-slow-a.fixture', socket.AF_INET6)]:
                        if (ipv4_only and family == socket.AF_INET6) or (ipv6_only and host == 'v4-slow-aaaa.fixture'):
                            continue
                        Target.families.clear()
                        status, body = traffic.request(client['mixed-port'], f'http://{host}:{target_port}/payload', False)
                        assert status == 200 and body == b'proxy-traffic-regression' * 4096, (protocol, host, status)
                        expected = {socket.AF_INET} if ipv4_only else {socket.AF_INET6} if ipv6_only else {socket.AF_INET, socket.AF_INET6} if host == 'dual.fixture' else {family}
                        assert len(Target.families) == 1 and Target.families[0] in expected, (case, host, Target.families)
                    # An AAAA-preferring client receives a synthetic IPv6 target,
                    # yet an IPv4-only proxy must reach its A address through
                    # the proxy, never via the host's working IPv6 loopback.
                    fake6 = dual.fake_dns_address(core_dns, 'dual.fixture', 28)
                    Target.families.clear()
                    status, body = traffic.request(client['mixed-port'], f'http://[{fake6}]:{target_port}/aaaa-preferred', False)
                    expected = {socket.AF_INET} if ipv4_only else {socket.AF_INET6} if ipv6_only else {socket.AF_INET, socket.AF_INET6}
                    assert status == 200 and len(Target.families) == 1 and Target.families[0] in expected, (case, status, Target.families)
                    if ipv4_only or ipv6_only:
                        for host in (['v6.fixture', '[::1]'] if ipv4_only else ['127.0.0.1']):
                            Target.families.clear()
                            try:
                                status, _ = traffic.request(client['mixed-port'], f'http://{host}:{target_port}/unreachable-v6', False)
                                assert status >= 400, (case, host, status)
                            except (OSError, http.client.HTTPException):
                                pass
                            assert not Target.families, (case, 'PROXY failure leaked to direct IPv6', Target.families)
                        assert traffic.request(client['mixed-port'], f'http://dual.fixture:{target_port}/still-running', False)[0] == 200
                    else:
                        check_udp(client['mixed-port'], udp_port)
                    print(f'PASS: {case} encrypted data, AAAA-preferring client, bounded failure/no DIRECT payload leak, surviving core')
                except BaseException:
                    for log in [client_log, server_log]:
                        log.flush()
                        log.seek(0)
                        print(log.read())
                    raise


if __name__ == '__main__':
    main()
