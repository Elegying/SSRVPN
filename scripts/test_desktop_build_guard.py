import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/desktop_build_guard.py'
spec = importlib.util.spec_from_file_location('desktop_guard', SCRIPT)
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class DesktopBuildGuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='guard space 中文 ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / '.fvmrc').write_text('{"flutter":"3.44.1"}', encoding='utf-8')
        self.defines = self.root / 'private.json'
        self.config = {'SSRVPN_USAGE_PROVIDERS': '[{"id":"private-sentinel"}]'}
        self.defines.write_text(json.dumps(self.config), encoding='utf-8')
        self.calls = []
        self.fail_test = False
        self.fail_build = False
        self.version = '3.44.1'

    def output(self, platform):
        return self.root / ('SSRVPN_Windows/build/windows/x64/runner/Release' if platform == 'windows' else 'SSRVPN_MacOS/build/macos/Build/Products/Release/SSRVPN.app')

    def fake_flutter(self, args, **kwargs):
        self.calls.append((args, kwargs))
        if args[1] == '--version':
            return subprocess.CompletedProcess(args, 0, json.dumps({'frameworkVersion': self.version}).encode())
        snapshot = Path(next(a.split('=', 1)[1] for a in args if a.startswith('--dart-define-from-file=')))
        if args[1] == 'test':
            self.assertEqual(snapshot.read_bytes(), self.defines.read_bytes())
            # Mutating the original after verification cannot affect compilation.
            self.defines.write_text('{"SSRVPN_USAGE_PROVIDERS":"[]"}', encoding='utf-8')
            return subprocess.CompletedProcess(args, int(self.fail_test), b'private-sentinel')
        self.assertEqual(json.loads(snapshot.read_text(encoding='utf-8')), self.config)
        if self.fail_build:
            raise subprocess.CalledProcessError(1, args)
        platform = args[2]
        relative = 'data/app.so' if platform == 'windows' else 'Contents/Frameworks/App.framework/App'
        target = self.output(platform) / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b'compiled fixture')
        return subprocess.CompletedProcess(args, 0)

    def build(self, platform='windows', test_only=False):
        with patch.object(guard.subprocess, 'run', side_effect=self.fake_flutter):
            return guard.build(platform, self.defines, test_only=test_only, root=self.root)

    def test_validated_snapshot_is_used_for_both_platform_builds_and_deleted(self):
        for platform in ['windows', 'macos']:
            self.defines.write_text(json.dumps(self.config), encoding='utf-8')
            output = self.build(platform)
            self.assertEqual(guard.verify(output, platform), 'verified')
            receipt = guard.receipt_path(output, platform).read_text(encoding='utf-8')
            self.assertNotIn('private-sentinel', receipt)
            self.assertNotIn('private.json', receipt)
            args, kwargs = self.calls[-2]
            self.assertEqual(kwargs['cwd'], self.root / 'packages/ssrvpn_shared')
            self.assertIn('--dart-define=SSRVPN_VERIFY_USAGE_BUILD=true', args)
            snapshot = Path(next(a.split('=', 1)[1] for a in args if a.startswith('--dart-define-from-file=')))
            self.assertFalse(snapshot.exists())

    def test_empty_malformed_missing_and_wrong_type_fail_before_flutter(self):
        for raw in ['{}', '{', 'null', '{"SSRVPN_USAGE_PROVIDERS":"[]"}', '{"SSRVPN_USAGE_PROVIDERS":"{}"}']:
            self.defines.write_text(raw, encoding='utf-8')
            with self.assertRaises((ValueError, TypeError, KeyError)):
                self.build()
            self.assertEqual(self.calls, [])
        self.defines.unlink()
        with self.assertRaises(OSError):
            self.build()

    def test_failed_test_invalidates_previous_receipt_and_never_builds(self):
        output = self.build()
        self.defines.write_text(json.dumps(self.config), encoding='utf-8')
        self.calls.clear()
        self.fail_test = True
        with self.assertRaises(ValueError):
            self.build()
        self.assertEqual([a[0][1] for a in self.calls], ['--version', 'test'])
        self.assertFalse(guard.receipt_path(output, 'windows').exists())

    def test_build_failure_leaves_no_receipt_or_snapshot(self):
        self.fail_build = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.build()
        self.assertFalse(guard.receipt_path(self.output('windows'), 'windows').exists())
        snapshot = Path(next(a.split('=', 1)[1] for a in self.calls[-1][0] if a.startswith('--dart-define-from-file=')))
        self.assertFalse(snapshot.exists())

    def test_wrong_flutter_version_rejected(self):
        self.version = '3.47.0'
        with self.assertRaises(ValueError):
            self.build()
        self.assertEqual(len(self.calls), 1)

    def test_concurrent_build_does_not_steal_lock_or_run(self):
        lock = self.root / 'SSRVPN_Windows/build/.ssrvpn-configuration.lock'
        lock.parent.mkdir(parents=True)
        lock.write_text('other build', encoding='utf-8')
        with self.assertRaises(FileExistsError):
            self.build()
        self.assertEqual(lock.read_text(), 'other build')
        self.assertEqual(self.calls, [])

    def test_missing_and_modified_receipts_or_binary_are_rejected(self):
        output = self.build()
        receipt = guard.receipt_path(output, 'windows')
        original = receipt.read_text(encoding='utf-8')
        for field, value in [('schema', 2), ('platform', 'macos'), ('profile', 'isolated-test'), ('sha256', '0' * 64)]:
            record = json.loads(original)
            record[field] = value
            receipt.write_text(json.dumps(record), encoding='utf-8')
            with self.assertRaises(ValueError):
                guard.verify(output, 'windows')
        receipt.write_text(original, encoding='utf-8')
        guard.artifact(output, 'windows').write_bytes(b'different app')
        with self.assertRaises(ValueError):
            guard.verify(output, 'windows')
        receipt.unlink()
        with self.assertRaises(OSError):
            guard.verify(output, 'windows')

    def test_payload_layout_preserves_binding(self):
        output = self.build()
        (output / 'bin').mkdir()
        (output / 'data').rename(output / 'bin/data')
        self.assertEqual(guard.verify(output, 'windows', payload=True), 'verified')

    def test_isolated_build_cannot_be_promoted_to_verified(self):
        self.config = {'SSRVPN_USAGE_PROVIDERS': '[]'}
        self.defines.write_text(json.dumps(self.config), encoding='utf-8')
        output = self.build(test_only=True)
        self.assertEqual([a[0][1] for a in self.calls], ['--version', 'build'])
        self.assertEqual(guard.verify(output, 'windows', test_only=True), 'isolated-test')
        with self.assertRaises(ValueError):
            guard.verify(output, 'windows')
        with self.assertRaises(ValueError):
            self.build('macos', test_only=True)

    def test_install_rejects_unverified_app_before_quit_or_copy(self):
        source = self.output('macos')
        with patch.object(guard.subprocess, 'run') as run:
            with self.assertRaises(OSError):
                guard.install_mac(source, self.root / 'installed.app')
            run.assert_not_called()

    def test_mac_install_stages_before_quit_and_retains_previous_app(self):
        source = self.build('macos')
        destination = self.root / 'SSRVPN.app'
        destination.mkdir()
        (destination / 'sentinel').write_text('old')
        calls = []

        def run(args, **kwargs):
            calls.append(args[0])
            if args[0] == 'ditto':
                shutil.copytree(args[1], args[2])
            if args[0] == 'osascript':
                self.assertTrue((destination / 'sentinel').exists())
            return subprocess.CompletedProcess(args, 1 if args[0] == 'pgrep' else 0)

        with patch.object(guard.subprocess, 'run', side_effect=run):
            guard.install_mac(source, destination)
        self.assertEqual(calls, ['ditto', 'codesign', 'osascript', 'pgrep'])
        self.assertEqual(len(list(self.root.glob('SSRVPN.previous-*.app/sentinel'))), 1)
        self.assertTrue(guard.artifact(destination, 'macos').exists())

    def test_cli_redacts_bad_configuration_and_disallows_override_arguments(self):
        self.defines.write_text('private-sentinel', encoding='utf-8')
        local_script = self.root / 'scripts/desktop_build_guard.py'
        local_script.parent.mkdir()
        shutil.copy2(SCRIPT, local_script)
        for extra in [[], ['--dart-define=SSRVPN_USAGE_PROVIDERS=private-sentinel']]:
            result = subprocess.run([sys.executable, str(local_script), 'build', '--platform', 'macos',
                                     '--dart-define-from-file', str(self.defines), *extra],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('private-sentinel', result.stdout + result.stderr)

    def test_mac_signature_failure_preserves_installed_app_without_quitting(self):
        source = self.build('macos')
        destination = self.root / 'SSRVPN.app'
        destination.mkdir()
        (destination / 'sentinel').write_text('old')
        calls = []

        def run(args, **kwargs):
            calls.append(args[0])
            if args[0] == 'ditto':
                shutil.copytree(args[1], args[2])
                return subprocess.CompletedProcess(args, 0)
            raise subprocess.CalledProcessError(1, args)

        with patch.object(guard.subprocess, 'run', side_effect=run):
            with self.assertRaises(subprocess.CalledProcessError):
                guard.install_mac(source, destination)
        self.assertEqual(calls, ['ditto', 'codesign'])
        self.assertEqual((destination / 'sentinel').read_text(), 'old')

    def test_mac_publish_failure_restores_previous_app(self):
        source = self.build('macos')
        destination = self.root / 'SSRVPN.app'
        destination.mkdir()
        (destination / 'sentinel').write_text('old')
        original_rename = Path.rename

        def rename(path, target):
            if path.parent.name.startswith('.ssrvpn-install-'):
                raise OSError('injected publish failure')
            return original_rename(path, target)

        def run(args, **kwargs):
            if args[0] == 'ditto':
                shutil.copytree(args[1], args[2])
            return subprocess.CompletedProcess(args, 1 if args[0] == 'pgrep' else 0)

        with patch.object(guard.subprocess, 'run', side_effect=run), patch.object(Path, 'rename', rename):
            with self.assertRaises(OSError):
                guard.install_mac(source, destination)
        self.assertEqual((destination / 'sentinel').read_text(), 'old')
        self.assertFalse(list(self.root.glob('SSRVPN.previous-*.app')))

    def test_entrypoints_fail_closed_and_ci_explicitly_marks_test_artifacts(self):
        windows = (ROOT / 'SSRVPN_Windows/tool/package_windows.ps1').read_text(encoding='utf-8')
        self.assertLess(windows.index('verify --platform windows --root $buildDir'), windows.index('Remove-Item -LiteralPath $releaseDir'))
        installer = (ROOT / 'SSRVPN_Windows/tool/build_installer.ps1').read_text(encoding='utf-8')
        self.assertLess(installer.index('verify --platform windows'), installer.index('New-TrustedPayloadManifest -PayloadRoot'))
        self.assertIn('/DBuildProfile=$buildProfile', installer)
        self.assertIn('/DSourceDir=$verifiedSourceDir', installer)
        self.assertNotIn('/DSourceDir=$SourceDir', installer)
        self.assertLess(installer.index('Copy-Item -LiteralPath $item.FullName'), installer.index('verify --platform windows --root $verifiedSourceDir'))
        self.assertLess(installer.index('verify --platform windows --root $verifiedSourceDir'), installer.index('New-TrustedPayloadManifest -PayloadRoot $verifiedSourceDir'))
        iss = (ROOT / 'SSRVPN_Windows/installer/SSRVPN.iss').read_text(encoding='utf-8')
        initialize = iss[iss.index('function InitializeSetup():'):]
        self.assertLess(initialize.index('SSRVPN_TEST_BUILD_BLOCKED'), initialize.index('InitializePowerShellEnvironment()'))
        for name in ['GITHUB_ACTIONS', 'RUNNER_ENVIRONMENT', 'RUNNER_OS', 'GITHUB_REPOSITORY']:
            self.assertIn('GetEnv(\'' + name + '\')', initialize)
        ci = (ROOT / '.github/workflows/ci.yml').read_text(encoding='utf-8')
        self.assertEqual(ci.count('-IsolatedTestBuild'), 2)
        self.assertLess(ci.index('test_windows_test_installer_guard.ps1'), ci.index('test_windows_installer_package.ps1 -InstallerPath'))
        self.assertNotIn('-IsolatedTestBuild', (ROOT / '.github/workflows/release.yml').read_text(encoding='utf-8'))
        mac = (ROOT / 'SSRVPN_MacOS/tool/package_macos.sh').read_text(encoding='utf-8')
        self.assertIn('APP_SNAPSHOT="$(mktemp -d "$PACKAGE_DIR/verified-app.XXXXXX")"', mac)
        snapshot = mac.index('APP_PATH="$APP_SNAPSHOT/$APP_NAME.app"')
        self.assertLess(snapshot, mac.index('verify --platform macos --root "$APP_PATH"', snapshot))
        self.assertLess(snapshot, mac.index('/usr/bin/codesign --force'))

    @unittest.skipUnless(os.name == 'nt', 'PowerShell entrypoints require Windows')
    def test_real_powershell_entrypoints_reject_unverified_artifacts(self):
        tool_root = self.root / 'SSRVPN_Windows/tool'
        tool_root.mkdir(parents=True)
        shutil.copytree(ROOT / 'SSRVPN_Windows/tool', tool_root, dirs_exist_ok=True)
        (self.root / 'scripts').mkdir()
        shutil.copy2(SCRIPT, self.root / 'scripts/desktop_build_guard.py')
        (self.root / 'SSRVPN_Windows/build/windows/x64/runner/Release').mkdir(parents=True)
        for script, args in [
            ('package_windows.ps1', ['-SkipBuild']),
            ('build_installer.ps1', ['-SourceDir', str(self.root), '-OutputDir', str(self.root / 'out')]),
        ]:
            result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                                     str(tool_root / script), *args], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'out').exists())


if __name__ == '__main__':
    unittest.main()
