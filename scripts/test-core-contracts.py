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
import urllib.error

ROOT = Path(__file__).resolve().parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


source = load('traffic_source', 'core-traffic-source.py')
builder = load('core_builder', 'build-core-asset.py')
events = load('core_contract_events', 'core-contract-events.py')
verify_events = events.verify_events


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


def run(platform, report_dir):
    record = json.loads((source.BUNDLE / 'sources.json').read_text())[platform]
    expected = contracts()
    report_dir.mkdir(parents=True, exist_ok=True)
    report = dict(platform=platform, source=record, extension_sha256=source.digest(),
                  status='failed', phase='toolchain', failure_kind='setup')
    log = report_dir / f'{platform}.jsonl'
    stderr_log = report_dir / f'{platform}.stderr.log'
    # A focused rerun must never classify an earlier run's events as current.
    log.write_text('')
    stderr_log.write_text('')
    try:
        go = builder.find_go(record['go'])
        environment = dict(os.environ, GOROOT=str(Path(go).parent.parent),
                           GOTOOLCHAIN='local', GOMAXPROCS='2', GOFLAGS='-trimpath')
        actual = subprocess.check_output([go, 'version'], env=environment, text=True).split()[2]
        if actual != record['go']:
            raise ValueError('Pinned Go version mismatch')
        with tempfile.TemporaryDirectory(prefix=f'ssrvpn-contracts-{platform}-') as folder:
            checkout = Path(folder) / 'core'
            report['phase'] = 'source-checkout'
            subprocess.run(['git', 'clone', '--quiet', '--filter=blob:none', '--no-checkout',
                            record['repository'], str(checkout)], check=True, timeout=300)
            subprocess.run(['git', 'checkout', '--quiet', record['commit']],
                           cwd=checkout, check=True, timeout=180)
            report.update(phase='source-verification', failure_kind='integrity')
            source.apply(platform, checkout)  # Checks both commit and tree before patching.
            tags = 'with_gvisor,cmfa' if platform == 'android' else 'with_gvisor'
            names = sorted({name for _, name in expected})
            packages = sorted({package.replace('github.com/metacubex/mihomo/', './', 1)
                               for package, _ in expected})
            command = [go, 'test', '-json', '-count=1', '-p', '2', '-timeout=120s',
                       '-tags=' + tags,
                       '-ldflags=-X github.com/metacubex/mihomo/constant.Version=' + record['version'] + '-ssrvpn.1',
                       '-run', '^(' + '|'.join(names) + ')$'] + packages
            report.update(phase='test-execution', failure_kind='execution')
            with log.open('w') as output, stderr_log.open('w') as errors:
                subprocess.run(command, cwd=checkout, env=environment, stdout=output,
                               stderr=errors, check=True, timeout=1200)
            report.update(phase='contract-verification', failure_kind='contract-incomplete')
            report['passed_contracts'] = verify_events(log, expected)
            report['status'] = 'passed'
            report['failure_kind'] = None
            print(f"{platform}: {report['passed_contracts']} core contracts passed", flush=True)
    except (Exception, SystemExit) as error:
        report['error'] = str(error)
        report['error_type'] = type(error).__name__
        if report['phase'] == 'toolchain' and isinstance(error, ValueError):
            report['failure_kind'] = 'integrity'
        elif report['phase'] == 'toolchain' and isinstance(error, SystemExit):
            report['failure_kind'] = 'environment'
        elif isinstance(error, (urllib.error.URLError, OSError)):
            report['failure_kind'] = 'environment'
        elif report['phase'] in ('toolchain', 'source-checkout') and isinstance(error, subprocess.TimeoutExpired):
            report['failure_kind'] = 'environment'
        if report['phase'] in ('test-execution', 'contract-verification'):
            try:
                report['failed_tests'] = events.failed_tests(events.read_events(log))
                if report['failed_tests']:
                    report['failure_kind'] = 'contract-failure'
            except (ValueError, KeyError) as event_error:
                report['event_error'] = str(event_error)
        raise RuntimeError(f"{report['phase']} [{report['failure_kind']}]: {error}") from error
    finally:
        (report_dir / f'{platform}.json').write_text(json.dumps(report, indent=2) + '\n')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=['android', 'macos', 'windows', 'all'])
    parser.add_argument('--report-dir', type=Path, required=True)
    args = parser.parse_args(argv)
    failures = []
    for target in (['macos', 'windows', 'android'] if args.platform == 'all' else [args.platform]):
        try:
            run(target, args.report_dir.resolve())
        except Exception as error:
            print(f'{target}: FAILED: {error}', flush=True)
            failures.append(target)
    if failures:
        raise SystemExit('Failed core platforms: ' + ', '.join(failures))


if __name__ == '__main__':
    main()
