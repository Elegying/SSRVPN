#!/usr/bin/env python3
"""Replay every shared Go contract against each pinned upstream, without rebuilding assets."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


source = load('traffic_source', 'core-traffic-source.py')
builder = load('core_builder', 'build-core-asset.py')


def contracts():
    expected = set()
    for filename, destination in source.COPIES.items():
        if not filename.endswith('_test.go'):
            continue
        package = 'github.com/metacubex/mihomo/' + str(Path(destination).parent)
        for name in re.findall(r'^func (Test\w+)\(', (source.BUNDLE / filename).read_text(), re.M):
            expected.add((package, name))
    if not expected:
        raise ValueError('No core contracts discovered')
    return expected


def verify_events(path, expected):
    passed = set()
    for line in path.read_text().splitlines():
        event = json.loads(line)
        if event.get('Action') == 'pass' and 'Test' in event:
            passed.add((event['Package'], event['Test']))
    missing = sorted(expected - passed)
    if missing:
        raise ValueError(f'Core contracts missing, skipped or failed: {missing}')
    return len(expected)


def run(platform, report_dir):
    record = json.loads((source.BUNDLE / 'sources.json').read_text())[platform]
    expected = contracts()
    report_dir.mkdir(parents=True, exist_ok=True)
    report = dict(platform=platform, source=record, extension_sha256=source.digest(), status='failed')
    try:
        go = builder.find_go(record['go'])
        environment = dict(os.environ, GOROOT=str(Path(go).parent.parent),
                           GOTOOLCHAIN='local', GOMAXPROCS='2', GOFLAGS='-trimpath')
        actual = subprocess.check_output([go, 'version'], env=environment, text=True).split()[2]
        if actual != record['go']:
            raise ValueError('Pinned Go version mismatch')
        with tempfile.TemporaryDirectory(prefix=f'ssrvpn-contracts-{platform}-') as folder:
            checkout = Path(folder) / 'core'
            subprocess.run(['git', 'clone', '--quiet', '--filter=blob:none', '--no-checkout',
                            record['repository'], str(checkout)], check=True, timeout=300)
            subprocess.run(['git', 'checkout', '--quiet', record['commit']],
                           cwd=checkout, check=True, timeout=180)
            source.apply(platform, checkout)  # Checks both commit and tree before patching.
            tags = 'with_gvisor,cmfa' if platform == 'android' else 'with_gvisor'
            names = sorted({name for _, name in expected})
            packages = sorted({package.replace('github.com/metacubex/mihomo/', './', 1)
                               for package, _ in expected})
            command = [go, 'test', '-json', '-count=1', '-p', '2', '-timeout=120s',
                       '-tags=' + tags,
                       '-ldflags=-X github.com/metacubex/mihomo/constant.Version=' + record['version'] + '-ssrvpn.1',
                       '-run', '^(' + '|'.join(names) + ')$'] + packages
            log = report_dir / f'{platform}.jsonl'
            with log.open('w') as output:
                subprocess.run(command, cwd=checkout, env=environment, stdout=output,
                               check=True, timeout=1200)
            report['passed_contracts'] = verify_events(log, expected)
            report['status'] = 'passed'
            print(f"{platform}: {report['passed_contracts']} core contracts passed", flush=True)
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        (report_dir / f'{platform}.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=['android', 'macos', 'windows', 'all'])
    parser.add_argument('--report-dir', type=Path, required=True)
    args = parser.parse_args()
    failures = []
    for target in (['macos', 'windows', 'android'] if args.platform == 'all' else [args.platform]):
        try:
            run(target, args.report_dir.resolve())
        except Exception as error:
            print(f'{target}: FAILED: {error}', flush=True)
            failures.append(target)
    if failures:
        raise SystemExit('Failed core platforms: ' + ', '.join(failures))
