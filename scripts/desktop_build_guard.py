"""Bind desktop build configuration acceptance to the compiled application bytes.

Receipts prevent accidental reuse, not deliberate forgery by a local developer.
No private configuration values are written to receipts or diagnostic output.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
RECEIPT = 'ssrvpn-build-verification.json'


class PrivateArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        # Unknown inline defines may themselves contain private values.
        self.exit(2, 'Unsupported or missing build/install arguments; use --help.\n')


def artifact(root, platform, payload=False):
    relative = ('bin/data/app.so' if payload else 'data/app.so') if platform == 'windows' else 'Contents/Frameworks/App.framework/App'
    path = root / relative
    if not path.resolve().is_relative_to(root.resolve()) or not path.is_file():
        raise ValueError('Missing compiled application')
    return path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def receipt_path(root, platform):
    return root / RECEIPT if platform == 'windows' else root.with_name(root.name + '.' + RECEIPT)


def verify(root, platform, test_only=False, payload=False):
    record = json.loads(receipt_path(root, platform).read_text(encoding='utf-8'))
    profile = 'isolated-test' if test_only else 'verified'
    if (not isinstance(record, dict) or record.get('schema') != 1 or record.get('platform') != platform or
            record.get('profile') != profile or
            record.get('sha256') != digest(artifact(root, platform, payload))):
        raise ValueError('Build verification does not match this artifact/profile')
    return profile


def build(platform, defines, flutter='flutter', test_only=False, root=ROOT):
    project = root / ('SSRVPN_Windows' if platform == 'windows' else 'SSRVPN_MacOS')
    lock = project / 'build/.ssrvpn-configuration.lock'
    lock.parent.mkdir(parents=True, exist_ok=True)
    # Do not steal a concurrent or interrupted build's lock.
    with lock.open('x', encoding='utf-8'):
        pass
    try:
        return _build(platform, defines, flutter, test_only, root, project)
    finally:
        lock.unlink()


def _build(platform, defines, flutter, test_only, root, project):
    output = project / ('build/windows/x64/runner/Release' if platform == 'windows' else 'build/macos/Build/Products/Release/SSRVPN.app')
    receipt = receipt_path(output, platform)
    # Invalidate before any attempt, including invalid input or failed tests.
    receipt.unlink(missing_ok=True)
    config_bytes = defines.read_bytes()
    config = json.loads(config_bytes.decode('utf-8-sig'))
    providers = json.loads(config['SSRVPN_USAGE_PROVIDERS'])
    if not isinstance(providers, list) or (not test_only and not providers):
        raise ValueError('Missing account configuration')
    if test_only and (platform != 'windows' or providers):
        raise ValueError('Isolated test builds require the empty Windows fixture')
    version = subprocess.run([flutter, '--version', '--machine'], capture_output=True, check=True)
    if json.loads(version.stdout)['frameworkVersion'] != json.loads((root / '.fvmrc').read_text(encoding='utf-8'))['flutter']:
        raise ValueError('Incorrect Flutter version')
    # Snapshot once: validation and compilation must consume identical bytes.
    with tempfile.TemporaryDirectory(prefix='ssrvpn-build-') as folder:
        snapshot = Path(folder) / 'defines.json'
        snapshot.write_bytes(config_bytes)
        snapshot.chmod(0o600)
        define_arg = '--dart-define-from-file=' + str(snapshot)
        if not test_only:
            result = subprocess.run([
                flutter, 'test', 'test/account_usage_compiled_theme_test.dart',
                define_arg, '--dart-define=SSRVPN_VERIFY_USAGE_BUILD=true',
            ], cwd=root / 'packages/ssrvpn_shared', capture_output=True)
            if result.returncode:
                # Flutter failures can include parsed private values.
                raise ValueError('Compiled configuration verification failed')
        args = [flutter, 'build', platform, '--release', '--split-debug-info=build/symbols', define_arg]
        if platform == 'windows':
            args.append('--no-pub')
        subprocess.run(args, cwd=project, check=True)
    record = dict(schema=1, platform=platform,
                  profile='isolated-test' if test_only else 'verified',
                  sha256=digest(artifact(output, platform)))
    receipt.write_text(json.dumps(record) + '\n', encoding='utf-8')
    return output


def install_mac(source, destination=Path('/Applications/SSRVPN.app')):
    verify(source, 'macos')
    # Stage and verify before quitting or changing the existing installation.
    with tempfile.TemporaryDirectory(prefix='.ssrvpn-install-', dir=destination.parent) as folder:
        staged = Path(folder) / 'SSRVPN.app'
        subprocess.run(['ditto', str(source), str(staged)], check=True)
        shutil.copy2(receipt_path(source, 'macos'), receipt_path(staged, 'macos'))
        verify(staged, 'macos')
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
        subprocess.run(['osascript', '-e', 'tell application "SSRVPN" to quit'], check=True)
        for _ in range(50):
            status = subprocess.run(['pgrep', '-x', 'SSRVPN'], capture_output=True).returncode
            if status == 1:
                break
            if status != 0:
                raise ValueError('Unable to confirm application exit')
            time.sleep(0.1)
        else:
            raise ValueError('Application has not exited; installation unchanged')
        backup = destination.with_name('SSRVPN.previous-' + uuid.uuid4().hex + '.app')
        existed = destination.exists()
        if existed:
            destination.rename(backup)
        try:
            staged.rename(destination)
        except OSError:
            if existed:
                backup.rename(destination)
            raise
    print('Verified application installed; previous application retained. User data unchanged.')


def main():
    parser = PrivateArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    b = sub.add_parser('build')
    b.add_argument('--platform', choices=['windows', 'macos'], required=True)
    b.add_argument('--dart-define-from-file', type=Path, default=ROOT / 'config/ssrvpn-private-defines.json')
    b.add_argument('--flutter', default='flutter')
    b.add_argument('--isolated-test-build', action='store_true')
    v = sub.add_parser('verify')
    v.add_argument('--platform', choices=['windows', 'macos'], required=True)
    v.add_argument('--root', type=Path, required=True)
    v.add_argument('--payload', action='store_true')
    v.add_argument('--isolated-test-build', action='store_true')
    i = sub.add_parser('install-macos')
    i.add_argument('--app', type=Path, default=ROOT / 'SSRVPN_MacOS/build/macos/Build/Products/Release/SSRVPN.app')
    args = parser.parse_args()
    try:
        if args.command == 'build':
            build(args.platform, args.dart_define_from_file.resolve(), args.flutter, args.isolated_test_build)
        elif args.command == 'verify':
            print(verify(args.root, args.platform, args.isolated_test_build, args.payload))
        else:
            if sys.platform != 'darwin':
                raise ValueError('macOS required')
            install_mac(args.app.resolve())
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print('Build/install did not complete. Check complete configuration, verified artifacts and tool/file access; existing backups are retained.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
