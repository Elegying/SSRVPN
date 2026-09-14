"""Mandatory candidate review before signing; standard library only."""
import fnmatch
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request


def review_routes(payloads, cases):
    def rule_matches(domain, value):
        suffix = value.startswith('+.')
        pattern = value[2:] if suffix else value
        # Most providers contain literal domains. Avoid repeatedly compiling
        # 100k+ literals through fnmatch's bounded regex cache for each case.
        if '*' not in pattern and '?' not in pattern:
            return domain == pattern or (suffix and domain.endswith('.' + pattern))
        return fnmatch.fnmatchcase(domain, pattern) or (
            suffix and fnmatch.fnmatchcase(domain, '*.' + pattern))

    def matches(domain, names):
        return any(rule_matches(domain, value)
                   for name in names for value in payloads[name])
    proxy = ['gfw.yaml', 'foreign_services.yaml', 'ai_services.yaml',
             'streaming_services.yaml', 'user_feedback_rules.yaml']
    direct = ['cn.yaml', 'china_domains.yaml']
    if set(cases) != {'direct', 'proxy', 'unknown'} or any(not cases[k] for k in cases):
        raise ValueError('review cases must contain direct, proxy and unknown targets')
    for decision, domains in cases.items():
        for domain in domains:
            proxied, bypassed = matches(domain, proxy), matches(domain, direct)
            valid = ((bypassed and not proxied) if decision == 'direct' else
                     (proxied and not bypassed) if decision == 'proxy' else
                     (not proxied and not bypassed))
            if not valid:
                raise ValueError(f'review blocked: route expectation mismatch: {domain} ({decision})')
    return sum(map(len, cases.values()))


def review_changes(payloads, previous_payloads, automated_files):
    rows = []
    for name, values in sorted(payloads.items()):
        current = set(values)
        previous = set(previous_payloads.get(name, []))
        added, removed = len(current - previous), len(previous - current)
        rows.append(f'| {name} | {len(previous)} | {len(current)} | {added} | {removed} |')
        # Count-only checks miss replacements that leave the total unchanged.
        if name in automated_files and previous and max(added, removed) > max(20, len(previous) * .1):
            raise ValueError(f'review blocked: excessive content replacement in {name}: +{added}/-{removed}')
    return '\n'.join(['| File | Previous | Candidate | Added | Removed |',
                      '| --- | ---: | ---: | ---: | ---: |', *rows])


def review_core(core, contents, entries):
    """Start an isolated core and require every provider to finish loading."""
    with tempfile.TemporaryDirectory(prefix='ssrvpn-rule-review-') as folder:
        root = Path(folder)
        for name, text in contents.items():
            (root / name).write_text(text)
        with socket.socket() as port:
            port.bind(('127.0.0.1', 0))
            api = port.getsockname()[1]
        providers = {e['name']: {'type': 'file', 'behavior': e['behavior'], 'format': 'yaml',
                                'path': str(root / e['name'])}
                     for e in entries if e['behavior'] != 'packages'}
        application_rules = [
            f'PROCESS-NAME,{json.loads(line[4:])},REJECT'
            for entry in entries if entry['behavior'] == 'packages'
            for line in contents[entry['name']].splitlines() if line.startswith('  - ')
        ]
        # Reject rules avoid any real outbound traffic; this gate checks loading,
        # not whether a public site happens to be reachable on the runner.
        config = {'mode': 'rule', 'external-controller': f'127.0.0.1:{api}',
                  'secret': 'isolated-rule-review', 'ipv6': False,
                  'dns': {'enable': False}, 'tun': {'enable': False},
                  'rule-providers': providers,
                  'rules': application_rules + [f'RULE-SET,{name},REJECT' for name in providers] + ['MATCH,REJECT']}
        (root / 'config.json').write_text(json.dumps(config))
        command = [str(Path(core).resolve()), '-d', folder, '-f', str(root / 'config.json')]
        subprocess.run([*command, '-t'], check=True, timeout=30, capture_output=True)
        with (root / 'core.log').open('w+') as log:
            process = subprocess.Popen(command, stdout=log, stderr=log)
            try:
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                for _ in range(100):
                    if process.poll() is not None:
                        raise ValueError('review blocked: core exited before providers became ready')
                    try:
                        request = urllib.request.Request(f'http://127.0.0.1:{api}/providers/rules',
                            headers={'Authorization': 'Bearer isolated-rule-review'})
                        with opener.open(request, timeout=.5) as response:
                            loaded = json.load(response)['providers']
                        if all(loaded.get(e['name'], {}).get('ruleCount') == e['count']
                               for e in entries if e['behavior'] != 'packages'):
                            return
                    except (OSError, ValueError, KeyError):
                        pass
                    time.sleep(.1)
                raise ValueError('review blocked: core provider load/count mismatch')
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def write_report(text):
    report = os.environ.get('GITHUB_STEP_SUMMARY')
    if report:
        with open(report, 'a') as output:
            output.write(text + '\n')
    print(text)
