#!/usr/bin/env python3
"""Loopback-only SS/Trojan/AnyTLS dual-stack data-path regression."""
from contextlib import ExitStack
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
    with ExitStack() as stack:
        folder = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='ssrvpn-protocol-dual-')))
        core = folder / 'core'
        core.write_bytes(gzip.decompress((ROOT / 'SSRVPN_MacOS/assets/AtlasCore.gz').read_bytes()))
        core.chmod(0o700)
        dns = traffic.serve(stack, socketserver.ThreadingUDPServer(('127.0.0.1', 0), DNS))
        target4 = traffic.ThreadingHTTPServer(('127.0.0.1', 0), Target)
        target_port = traffic.serve(stack, target4)
        traffic.serve(stack, dual.IPv6HTTP(('::1', target_port), Target))
        udp_port = traffic.serve(stack, socketserver.ThreadingUDPServer(('127.0.0.1', 0), Echo))
        traffic.serve(stack, UDP6(('::1', udp_port), Echo))
        cert, key = folder / 'cert.pem', folder / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=proxy.fixture', '-addext', 'subjectAltName=DNS:proxy.fixture', '-keyout', str(key), '-out', str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for protocol in ['ss', 'trojan', 'anytls']:
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
                server.update(listeners=[listener], rules=['MATCH,DIRECT'])
                _, server_log = launch(run, core, folder / f'{protocol}-server', server)
                client = base_config()
                client['tls'] = {'custom-certifactes': [cert.read_text()]}
                client.update(dns={'enable': True, 'ipv6': True, 'nameserver': [f'127.0.0.1:{dns}']}, proxies=[proxy], rules=['MATCH,fixture'])
                _, client_log = launch(run, core, folder / f'{protocol}-client', client)
                try:
                    deadline = time.monotonic() + 10
                    while traffic.request(client['mixed-port'], f'http://dual.fixture:{target_port}/ready', False)[0] != 200:
                        if time.monotonic() >= deadline:
                            raise AssertionError('protocol route did not become ready')
                        time.sleep(.05)
                    for host, family in [('dual.fixture', socket.AF_INET), ('v6.fixture', socket.AF_INET6), ('[::1]', socket.AF_INET6), ('v4-slow-aaaa.fixture', socket.AF_INET), ('v6-slow-a.fixture', socket.AF_INET6)]:
                        Target.families.clear()
                        status, body = traffic.request(client['mixed-port'], f'http://{host}:{target_port}/payload', False)
                        assert status == 200 and body == b'proxy-traffic-regression' * 4096, (protocol, host, status)
                        assert Target.families == [family], (protocol, host, Target.families)
                    check_udp(client['mixed-port'], udp_port)
                    print(f'PASS: {protocol} encrypted TCP/UDP data, IPv4 preference, IPv6-only, literal IPv6 and UDP association reuse')
                except BaseException:
                    for log in [client_log, server_log]:
                        log.flush()
                        log.seek(0)
                        print(log.read())
                    raise


if __name__ == '__main__':
    main()
