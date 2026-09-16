#!/usr/bin/env python3
"""Exercise generated SSRVPN rules on loopback; no system proxy/TUN changes."""
from contextlib import ExitStack
import gzip
import importlib.util
import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('traffic', ROOT / 'scripts/check-core-proxy-traffic.py')
traffic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(traffic)


class RoutingProxy(traffic.ConnectProxy):
    def handle(self):
        # Only the four synthetic fixture targets can reach the loopback backend.
        original = self.rfile.readline().decode()
        method, destination, _ = original.split()
        assert method == 'CONNECT'
        host, port = destination.rsplit(':', 1)
        if host == 'www.gstatic.com':
            self.wfile.write(b'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n')
            return
        assert host in {'127.0.0.1', '1.1.1.1', 'youtube.com', 'unclassified.ssrvpn.invalid', 'manual-proxy.example'}, (method, host, port)
        while self.rfile.readline() not in (b'\r\n', b'\n', b''):
            pass
        with socket.create_connection(('127.0.0.1', int(port)), timeout=5) as remote:
            self.wfile.write(b'HTTP/1.1 200 Connection Established\r\n\r\n')
            self.wfile.flush()
            peers = [self.connection, remote]
            while True:
                ready, _, _ = traffic.select.select(peers, [], [], 10)
                if not ready:
                    return
                for source in ready:
                    data = source.recv(65536)
                    if not data:
                        return
                    (remote if source is self.connection else self.connection).sendall(data)


def main():
    with ExitStack() as stack:
        folder = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='ssrvpn-routing-core-')))
        target = traffic.serve(stack, traffic.ThreadingHTTPServer(('127.0.0.1', 0), traffic.Target))
        proxy = traffic.serve(stack, traffic.ProxyServer(('127.0.0.1', 0), RoutingProxy))
        ports = set()
        while len(ports) < 3:
            ports.add(traffic.free_port())
        mixed, api, socks = sorted(ports)
        shutil.copytree(ROOT / 'packages/ssrvpn_shared/assets/rules/latest', folder / 'providers/bundles/2.0.0')
        environment = dict(os.environ, SSRVPN_ROUTING_FIXTURE=str(folder), SSRVPN_ROUTING_PORTS=json.dumps({'proxy': proxy, 'mixed': mixed, 'api': api, 'socks': socks}))
        generated = subprocess.run(
            ['flutter', 'test', '--no-pub', 'packages/ssrvpn_shared/test/signed_rule_snapshot_test.dart'],
            cwd=ROOT, env=environment, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True,
        )
        if generated.returncode != 0:
            raise AssertionError('Routing fixture generation failed:\n' + generated.stdout)
        core = folder / 'AtlasCore'
        core.write_bytes(gzip.decompress((ROOT / 'SSRVPN_MacOS/assets/AtlasCore.gz').read_bytes()))
        core.chmod(0o700)
        (folder / 'geoip.metadb').write_bytes(gzip.decompress((ROOT / 'SSRVPN_MacOS/assets/geoip.metadb.gz').read_bytes()))
        for mode in ['rule', 'global', 'fallback', 'recovered']:
            with (folder / f'{mode}.log').open('w+') as log:
                process = subprocess.Popen([str(core), '-d', str(folder), '-f', str(folder / f'{mode}.yaml')], stdout=log, stderr=log)
                try:
                    traffic.wait_for_core(process, log, api, mixed)
                    # Match the desktop TUN startup budget. Open sockets alone
                    # do not mean the asynchronous providers/router are usable.
                    # Probe only the synthetic direct target; no external network.
                    deadline = time.monotonic() + 45
                    providers, ready_status = {}, None
                    while time.monotonic() < deadline:
                        if process.poll() is not None:
                            raise AssertionError('core exited during readiness')
                        status, body = traffic.request(api, '/providers/rules')
                        providers = json.loads(body).get('providers', {}) if status == 200 else {}
                        if len(providers) == 8 and all(p.get('ruleCount', 0) > 0 for p in providers.values()):
                            ready_status, ready_body = traffic.request(
                                mixed, f'http://google.com:{target}/payload', False)
                            if ready_status == 200 and ready_body == b'proxy-traffic-regression' * 4096:
                                break
                        time.sleep(.05)
                    else:
                        raise AssertionError(('core not ready', providers, ready_status))
                    def sample():
                        status, body = traffic.request(api, '/ssrvpn/traffic')
                        assert status == 200
                        return json.loads(body)['download']
                    for domain, expected_proxy in [('google.com', False), ('manual-proxy.example', True), ('youtube.com', True), ('unclassified.ssrvpn.invalid', True)]:
                        before = sample()
                        status, body = traffic.request(mixed, f'http://{domain}:{target}/payload', False)
                        assert status == 200 and body == b'proxy-traffic-regression' * 4096, (mode, domain, status, body[:200])
                        after = sample()
                        assert (after > before) == expected_proxy, (mode, domain, before, after)
                    print(f'{mode}: manual overrides, GFW proxy and unknown fallback passed on real core')
                except BaseException:
                    log.flush()
                    log.seek(0)
                    print(log.read())
                    print((folder / f'{mode}.yaml').read_text()[-2400:])
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
