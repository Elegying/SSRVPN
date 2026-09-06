#!/usr/bin/env python3
"""Rebuild a missing extended core without publishing a Release asset."""

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
BUNDLE = ROOT / 'native/proxy_traffic'


def verified_archive(source, target, record):
    digest = hashlib.sha256()
    total = 0
    with target.open('wb') as output:
        while chunk := source.read(1024 * 1024):
            total += len(chunk)
            if total > record['size']:
                raise ValueError('Go archive exceeds pinned size')
            digest.update(chunk)
            output.write(chunk)
    if total != record['size'] or digest.hexdigest() != record['sha256']:
        raise ValueError('Go archive does not match pinned digest/size')


def find_go(version):
    candidates = [os.environ.get('GO_BIN'), shutil.which('go'),
                  str(Path.home() / '.local/share/mise/installs/go' / version[2:] / 'bin/go')]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            result = subprocess.run([candidate, 'version'], capture_output=True, text=True, check=False)
            if result.returncode == 0 and result.stdout.split()[2] == version:
                return str(Path(candidate).resolve())
    host = {('Linux', 'x86_64'): 'linux-amd64',
            ('Darwin', 'arm64'): 'darwin-arm64'}.get((platform.system(), platform.machine()))
    if host is None:
        raise SystemExit('Install the pinned Go toolchain, or download core-assets from the matching CI run.')
    name = f'{version}.{host}.tar.gz'
    record = json.loads((BUNDLE / 'toolchains.json').read_text())[name]
    cache = Path.home() / '.cache/ssrvpn-core-toolchains' / f'{version}-{host}'
    executable = cache / 'go/bin/go'
    if executable.is_file():
        return str(executable)
    cache.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=cache.parent) as folder:
        folder = Path(folder)
        archive = folder / name
        with urllib.request.urlopen(f'https://go.dev/dl/{name}', timeout=120) as response:
            verified_archive(response, archive, record)
        with tarfile.open(archive) as source:
            source.extractall(folder / 'unpacked', filter='data')
        (folder / 'unpacked').rename(cache)
    return str(executable)


def build(target, output):
    record = json.loads((BUNDLE / 'sources.json').read_text())[target]
    environment = dict(os.environ, GO_BIN=find_go(record['go']))
    if target == 'android':
        sdk = environment.get('ANDROID_SDK_ROOT') or environment.get('ANDROID_HOME')
        if not sdk and platform.system() == 'Darwin':
            sdk = str(Path.home() / 'Library/Android/sdk')
        if not sdk:
            raise SystemExit('Android SDK is required to rebuild libgojni.so.')
        environment['ANDROID_SDK_ROOT'] = sdk
        ndk = Path(sdk) / 'ndk/28.2.13676358'
        if not ndk.is_dir():
            manager = shutil.which('sdkmanager') or str(Path(sdk) / 'cmdline-tools/latest/bin/sdkmanager')
            subprocess.run([manager, 'ndk;28.2.13676358'], env=environment, check=True)
        if not environment.get('JAVA_HOME'):
            for home in ['/usr/lib/jvm/temurin-17-jdk-amd64',
                         '/usr/lib/jvm/java-17-openjdk-amd64',
                         '/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home']:
                if (Path(home) / 'bin/javac').is_file():
                    environment['JAVA_HOME'] = home
                    break
        subprocess.run(['bash', str(ROOT / 'scripts/build-android-core.sh'), str(output)],
                       env=environment, check=True)
    else:
        with tempfile.TemporaryDirectory(prefix='ssrvpn-core-asset-') as folder:
            binary = Path(folder) / 'core'
            subprocess.run(['bash', str(ROOT / 'scripts/build-desktop-core.sh'), target, str(binary)],
                           env=environment, check=True)
            if target == 'macos':
                archive = bytearray(gzip.compress(binary.read_bytes(), compresslevel=9, mtime=0))
                archive[9] = 255  # Stable OS header across Python 3.11-3.13.
                output.write_bytes(archive)
            else:
                shutil.copyfile(binary, output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=['android', 'macos', 'windows'])
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    build(args.platform, args.output.resolve())
