#!/usr/bin/env python3
"""Apply and verify the pinned, shared proxy-only traffic core extension."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / 'native/proxy_traffic'
RUNTIME_FILES = ('sources.json', 'proxy_traffic.go', 'route.go',
                 'android.patch', 'macos.patch', 'windows.patch')
COPIES = {
    'proxy_traffic.go': 'tunnel/statistic/ssrvpn_proxy_traffic.go',
    'proxy_traffic_test.go': 'tunnel/statistic/ssrvpn_proxy_traffic_test.go',
    'route.go': 'hub/route/ssrvpn_proxy_traffic.go',
    'route_test.go': 'hub/route/ssrvpn_proxy_traffic_test.go',
    'outbound_test.go': 'adapter/outbound/ssrvpn_proxy_traffic_test.go',
}


def digest():
    value = hashlib.sha256()
    for name in RUNTIME_FILES:
        value.update(name.encode() + b'\0' + (BUNDLE / name).read_bytes() + b'\0')
    return value.hexdigest()


def apply(platform, directory):
    source = json.loads((BUNDLE / 'sources.json').read_text())[platform]
    for ref, expected in [('HEAD', source['commit']), ('HEAD^{tree}', source['tree'])]:
        actual = subprocess.check_output(['git', 'rev-parse', ref], cwd=directory, text=True).strip()
        if actual != expected:
            raise SystemExit(f'{platform} core source identity mismatch: {ref}')
    patch = BUNDLE / (platform + '.patch')
    subprocess.run(['git', 'apply', '--check', str(patch)], cwd=directory, check=True)
    # Check every destination before modifying the checkout.
    if any((directory / target).exists() for target in COPIES.values()):
        raise SystemExit('core traffic extension is already present')
    subprocess.run(['git', 'apply', str(patch)], cwd=directory, check=True)
    for name, target in COPIES.items():
        shutil.copyfile(BUNDLE / name, directory / target)
    if platform in ('android', 'windows'):
        # These pinned upstream versions use the unexported UDP constructor.
        target = directory / COPIES['outbound_test.go']
        target.write_text(target.read_text().replace('NewPacketConn(', 'newPacketConn('))
    print(f'Applied {platform} proxy traffic extension {digest()}')


def verify():
    sources = json.loads((BUNDLE / 'sources.json').read_text())
    for platform, record in [('android', 'SSRVPN_Android/assets/libgojni-source.txt'),
                             ('macos', 'SSRVPN_MacOS/assets/AtlasCore-source.txt'),
                             ('windows', 'SSRVPN_Windows/assets/mihomo-source.txt')]:
        fields = dict(line.split(': ', 1) for line in (ROOT / record).read_text().splitlines() if ': ' in line)
        expected = {'Traffic extension SHA256': digest(),
                    'Source commit': sources[platform]['commit'],
                    'Source tree': sources[platform]['tree'],
                    'Go version': sources[platform]['go']}
        for name, value in expected.items():
            if fields.get(name) != value:
                raise SystemExit(f'{record}: {name} does not match pinned traffic source')
    print('Three-platform proxy traffic source contracts verified.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['apply', 'verify', 'digest'])
    parser.add_argument('platform', nargs='?', choices=['android', 'macos', 'windows'])
    parser.add_argument('directory', nargs='?', type=Path)
    args = parser.parse_args()
    if args.operation == 'apply':
        if args.platform is None or args.directory is None:
            parser.error('apply requires platform and source directory')
        apply(args.platform, args.directory)
    elif args.operation == 'verify':
        verify()
    else:
        print(digest())
