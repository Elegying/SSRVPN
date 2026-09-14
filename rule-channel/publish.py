#!/usr/bin/env python3
"""Build a bounded, signed SSRVPN data snapshot; never accept upstream policies."""
import argparse
import ast
import base64
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request
from review import review_changes, review_core, review_routes, write_report

ROOT = Path(__file__).resolve().parent
LIMIT = 4 * 1024 * 1024
UPSTREAM = 'Loyalsoldier/clash-rules'
SOURCES = {'cn.yaml': 'direct.txt', 'gfw.yaml': 'gfw.txt',
           'foreign_services.yaml': 'proxy.txt', 'company_asn.yaml': 'cncidr.txt'}
PACKAGE = re.compile(r'[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+')
DOMAIN = re.compile(r'(?:\+\.)?[a-z0-9_*?][a-z0-9._*?+-]*')
VERSION = re.compile(r'(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})\.(?:0|[1-9][0-9]{0,8})')
# Common browsers must follow destination rules. Review this list alongside additions.
BROWSERS = {'com.android.chrome', 'com.chrome.beta', 'com.chrome.dev', 'com.chrome.canary',
 'com.google.android.apps.chrome', 'com.microsoft.emmx', 'org.mozilla.firefox',
 'org.mozilla.fenix', 'org.mozilla.focus', 'com.brave.browser', 'com.opera.browser',
 'com.opera.mini.native', 'com.sec.android.app.sbrowser', 'com.android.browser',
 'com.heytap.browser', 'com.vivo.browser', 'com.huawei.browser', 'com.mi.globalbrowser',
 'com.tencent.mtt', 'com.UCMobile', 'com.quark.browser', 'com.ssrvpn.android'}


def fetch(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'SSRVPN-rules-builder/2'})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read(LIMIT + 1)
    if not data or len(data) > LIMIT:
        raise ValueError('upstream exceeds size limit')
    return data.decode('utf-8')


def read_payload(text, behavior):
    if len(text.encode()) > LIMIT:
        raise ValueError('payload too large')
    if behavior == 'packages' and text.strip() == 'payload: []':
        return []
    values = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#') or line == 'payload:':
            continue
        if not line.startswith('- '):
            raise ValueError('only payload lists are accepted')
        value = line[2:].strip()
        if value.startswith(('"', "'")):
            value = ast.literal_eval(value)
        if not isinstance(value, str) or value in values[-1:]:
            raise ValueError('invalid payload')
        if behavior == 'domain':
            value = value.lower()
            if not DOMAIN.fullmatch(value) or not re.search('[a-z0-9]', value) or value in {'*', '+.*', '+.com', '+.net', '+.org'}:
                raise ValueError(f'invalid domain: {value}')
        elif behavior == 'ipcidr':
            network = ipaddress.ip_network(value, strict=True)
            if network.prefixlen == 0:
                raise ValueError('catch-all network forbidden')
        elif not PACKAGE.fullmatch(value) or value in BROWSERS or len(value) > 255:
            raise ValueError('invalid or excluded application')
        values.append(value)
    result = sorted(set(values))
    if not result or len(result) > 200000:
        raise ValueError('invalid payload count')
    return result


def encode(values):
    if not values:
        return 'payload: []\n'
    return 'payload:\n' + ''.join('  - ' + json.dumps(value) + '\n' for value in values)


def sync_latest(snapshot):
    latest = ROOT / 'latest'
    latest.mkdir(exist_ok=True)
    # Index last: readers always use its immutable snapshot, never mixed latest payloads.
    for file in sorted(snapshot.iterdir(), key=lambda p: p.name == 'version.json'):
        temporary = latest / (file.name + '.tmp')
        temporary.write_bytes(file.read_bytes())
        os.replace(temporary, latest / file.name)


def bump(version):
    if not VERSION.fullmatch(version):
        raise ValueError('invalid version')
    major, minor, patch = map(int, version.split('.'))
    updated = f'{major}.{minor}.{patch + 1}'
    version_tuple(updated)
    return updated


def version_tuple(version):
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise ValueError('invalid version')
    return tuple(map(int, version.split('.')))


def build(key, upstream_commit=None, *, core):
    latest = ROOT / 'latest'
    previous = None
    previous_snapshot = None
    if (latest / 'version.json').exists():
        descriptor = json.loads((latest / 'version.json').read_text())
        version_tuple(descriptor['version'])
        previous_snapshot = ROOT / 'snapshots' / descriptor['version']
        manifest_bytes = (previous_snapshot / 'manifest.json').read_bytes()
        if hashlib.sha256(manifest_bytes).hexdigest() != descriptor['manifestSha256']:
            raise ValueError('previous snapshot manifest mismatch')
        previous = json.loads(manifest_bytes)
    old_entries = {e['name']: e for e in previous['files']} if previous else {}
    commit = upstream_commit or json.loads(fetch(f'https://api.github.com/repos/{UPSTREAM}/commits/release'))['sha']
    if not re.fullmatch('[0-9a-f]{40}', commit):
        raise ValueError('invalid upstream revision')
    payloads = {}
    # Preserve the narrow built-in supplemental sets; mainstream lists are upstream-owned.
    for name in ['ai_services.yaml', 'streaming_services.yaml', 'china_domains.yaml', 'user_feedback_rules.yaml']:
        payloads[name] = read_payload((ROOT / 'baseline' / name).read_text(), 'domain')
    for name, source in SOURCES.items():
        behavior = 'ipcidr' if name == 'company_asn.yaml' else 'domain'
        values = read_payload(fetch(f'https://raw.githubusercontent.com/{UPSTREAM}/{commit}/{source}'), behavior)
        old_count = old_entries.get(name, {}).get('count')
        if old_count and not 0.8 * old_count <= len(values) <= 1.2 * old_count:
            raise ValueError(f'abnormal upstream count change: {name}')
        payloads[name] = values
    cases = json.loads((ROOT / 'review-cases.json').read_text())
    checked = review_routes(payloads, cases)
    write_report(f'Routing expectations: {checked} PASS')
    components = dict(previous['componentVersions']) if previous else {'rules': '2.0.0', 'directApps': '1.0.0', 'proxyApps': '1.0.0'}
    for stem, component, filename in [('direct-apps', 'directApps', 'direct_apps.yaml'), ('proxy-apps', 'proxyApps', 'proxy_apps.yaml')]:
        data = json.loads((ROOT / 'lists' / (stem + '.json')).read_text())
        version_tuple(data['version'])
        payloads[filename] = read_payload(encode(data['packages']), 'packages')
        if len(payloads[filename]) != len(data['packages']):
            raise ValueError('duplicate application')
        components[component] = data['version']
    if set(payloads['direct_apps.yaml']) & set(payloads['proxy_apps.yaml']):
        raise ValueError('conflicting application lists')
    contents = {name: encode(values) for name, values in payloads.items()}
    entries = [{'name': name, 'behavior': ('packages' if name.endswith('_apps.yaml') else 'ipcidr' if name == 'company_asn.yaml' else 'domain'),
                'count': len(payloads[name]), 'sha256': hashlib.sha256(text.encode()).hexdigest()} for name, text in sorted(contents.items())]
    previous_payloads = {}
    for name, entry in old_entries.items():
        old_text = (previous_snapshot / name).read_text()
        if hashlib.sha256(old_text.encode()).hexdigest() != entry['sha256']:
            raise ValueError('previous snapshot payload mismatch')
        previous_payloads[name] = read_payload(old_text, entry['behavior'])
    write_report('## Candidate rule review\nSource commit: `' + commit + '`')
    write_report(review_changes(payloads, previous_payloads, SOURCES))
    review_core(core, contents, entries)
    write_report('Core syntax and every provider count: PASS')
    changed = {e['name'] for e in entries if e['sha256'] != old_entries.get(e['name'], {}).get('sha256')}
    if previous:
        for component, filename in [('directApps', 'direct_apps.yaml'), ('proxyApps', 'proxy_apps.yaml')]:
            old_version = previous['componentVersions'][component]
            if filename in changed and version_tuple(components[component]) <= version_tuple(old_version):
                components[component] = bump(old_version)
            elif filename not in changed:
                components[component] = old_version
        if changed - {'direct_apps.yaml', 'proxy_apps.yaml'}:
            components['rules'] = bump(components['rules'])
        if not changed:
            sync_latest(previous_snapshot)
            print('No content changes; keep published snapshot.')
            return
    version = bump(previous['version']) if previous else '2.0.0'
    manifest = {'schemaVersion': 1, 'version': version, 'componentVersions': components,
                'upstream': {'repository': UPSTREAM, 'commit': commit}, 'files': entries}
    manifest_text = json.dumps(manifest, ensure_ascii=False, indent=2) + '\n'
    digest = hashlib.sha256(manifest_text.encode()).hexdigest()
    signed = f'SSRVPN rules v1\n{version}\n{digest}\n'.encode()
    with tempfile.TemporaryDirectory() as temporary:
        message = Path(temporary) / 'message'
        signature = Path(temporary) / 'signature'
        message.write_bytes(signed)
        subprocess.run(['openssl', 'pkeyutl', '-sign', '-rawin', '-inkey', str(key), '-in', str(message), '-out', str(signature)], check=True)
        # Refuse publication if the secret does not match the client trust key.
        subprocess.run(['openssl', 'pkeyutl', '-verify', '-rawin', '-pubin', '-inkey', str(ROOT / 'public-key.pem'), '-in', str(message), '-sigfile', str(signature)], check=True, stdout=subprocess.DEVNULL)
        descriptor = {'schemaVersion': 1, 'version': version, 'manifestSha256': digest, 'signature': base64.b64encode(signature.read_bytes()).decode()}
    contents['manifest.json'] = manifest_text
    contents['version.json'] = json.dumps(descriptor, indent=2) + '\n'
    if any(len(text.encode()) > LIMIT for text in contents.values()):
        raise ValueError('encoded data exceeds size limit')
    snapshot = ROOT / 'snapshots' / version
    snapshot.parent.mkdir(parents=True, exist_ok=True)
    if snapshot.exists():
        if any((snapshot / name).read_text() != text for name, text in contents.items()):
            raise ValueError('refusing to overwrite immutable snapshot')
    else:
        with tempfile.TemporaryDirectory(dir=snapshot.parent) as temporary:
            staged = Path(temporary) / 'complete'
            staged.mkdir()
            for name, text in contents.items():
                (staged / name).write_text(text)
            staged.rename(snapshot)
    sync_latest(snapshot)
    print(f'Prepared signed snapshot {version}: {len(changed)} changed files.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--key', required=True, type=Path)
    parser.add_argument('--upstream-commit')
    parser.add_argument('--core', required=True, type=Path)
    args = parser.parse_args()
    try:
        build(args.key, args.upstream_commit, core=args.core)
    except Exception as error:
        write_report(f'Rule review/publication FAILED: {type(error).__name__}: {error}')
        raise
