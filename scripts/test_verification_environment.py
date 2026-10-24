import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ENVIRONMENT = ROOT / 'scripts/verification-environment.sh'


class VerificationEnvironmentTests(unittest.TestCase):
    def shell(self, command, *, env=None, arguments=()):
        return subprocess.run(
            [shutil.which('bash') or 'bash', '-c', command, 'verification-test', *map(str, arguments)],
            cwd=ROOT, env=env, capture_output=True, text=True,
            encoding='utf-8', errors='replace', timeout=30,
        )

    def test_store_alias_fallback_survives_child_bash_and_uses_utf8(self):
        with tempfile.TemporaryDirectory(prefix='verification space ') as directory:
            folder = Path(directory)
            (folder / 'python3').write_text('#!/usr/bin/env bash\nexit 49\n', encoding='utf-8')
            executable = shlex.quote(Path(sys.executable).as_posix())
            (folder / 'python').write_text(
                f'#!/usr/bin/env bash\nexec {executable} "$@"\n', encoding='utf-8')
            for path in folder.iterdir():
                path.chmod(0o755)
            probe = folder / 'child.py'
            probe.write_text(
                'import shutil, subprocess\n'
                'subprocess.run([shutil.which("bash"), "-c", '
                '"python3 -c \'import sys; print(sys.flags.utf8_mode)\'"], check=True)\n',
                encoding='utf-8',
            )
            env = os.environ.copy()
            env['PATH'] = str(folder) + os.pathsep + env['PATH']
            env['PYTHONUTF8'] = '0'
            result = self.shell(
                'source "$1"; trap cleanup_verification_environment EXIT; '
                'prepare_verification_environment || exit; '
                'python3 "$2"',
                env=env, arguments=(ENVIRONMENT, probe),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), '1')

    def test_unusable_python_fails_before_other_work(self):
        result = self.shell(
            'source "$1"; python3() { return 49; }; python() { return 49; }; '
            'prepare_verification_environment || exit $?; echo SHOULD_NOT_RUN',
            arguments=(ENVIRONMENT,),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Python 3.12', result.stderr)
        self.assertNotIn('SHOULD_NOT_RUN', result.stdout)

    def test_missing_openssl_has_actionable_error(self):
        result = self.shell(
            'source "$1"; command() { '
            'if [[ "$*" == "-v openssl" ]]; then return 1; fi; '
            'builtin command "$@"; }; check_verification_prerequisites',
            arguments=(ENVIRONMENT,),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing: openssl', result.stderr)

    def test_explicit_native_toolchain_paths_are_preserved_and_rejected_if_unusable(self):
        result = self.shell(
            'source "$1"; trap cleanup_verification_environment EXIT; '
            'uname() { echo MINGW64_NT; }; '
            'export JAVA_HOME=/user-selected/missing-jdk ANDROID_SDK_ROOT=/user-selected/sdk; '
            'prepare_verification_environment || exit; '
            'printf "%s\\n" "$JAVA_HOME" "$ANDROID_SDK_ROOT"; '
            'check_verification_prerequisites',
            arguments=(ENVIRONMENT,),
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.splitlines()[:2],
                         ['/user-selected/missing-jdk', '/user-selected/sdk'])
        self.assertIn('JDK 17', result.stderr)

    def test_boundary_guard_is_independent_of_default_text_encoding(self):
        guard = (ROOT / 'scripts/check-clash-service-boundaries.sh').read_text(encoding='utf-8')
        code = guard.split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        shim = (
            'from pathlib import Path\n'
            '_read = Path.read_text\n'
            'def legacy_read(self, *args, **kwargs):\n'
            '    kwargs.setdefault("encoding", "gbk")\n'
            '    return _read(self, *args, **kwargs)\n'
            'Path.read_text = legacy_read\n'
        )
        result = subprocess.run(
            [sys.executable, '-c', shim + code], cwd=ROOT,
            capture_output=True, text=True, encoding='utf-8', timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('responsibility boundaries passed', result.stdout)

    def test_unknown_mode_is_rejected(self):
        result = subprocess.run(
            [shutil.which('bash') or 'bash', str(ROOT / 'scripts/verify-all.sh'), '--skip-assets'],
            cwd=ROOT, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn('usage:', result.stderr)

    @unittest.skipUnless(os.name == 'nt', 'Windows PowerShell 5.1 required')
    def test_windows_wrapper_preserves_exit_code_and_passes_paths_with_spaces(self):
        bash = Path(shutil.which('bash')).resolve()
        with tempfile.TemporaryDirectory(prefix='verification path ') as directory:
            root = Path(directory)
            scripts = root / 'scripts'
            scripts.mkdir()
            shutil.copyfile(ROOT / 'scripts/verify-windows.ps1', scripts / 'verify-windows.ps1')
            (scripts / 'verify-all.sh').write_text(
                '#!/usr/bin/env bash\n'
                'test "${1:-}" = "$EXPECTED_MODE" || exit 9\n'
                'test -f scripts/verify-windows.ps1 || exit 10\n'
                'command -v openssl >/dev/null || exit 11\n'
                'exit 23\n', encoding='utf-8',
            )
            driver = root / 'driver.ps1'
            driver.write_text(
                'param([string]$BashPath, [string]$Mode)\n'
                '$beforePath = $env:PATH\n$beforeLocation = (Get-Location).Path\n'
                '& (Join-Path $PSScriptRoot "scripts/verify-windows.ps1") -BashPath $BashPath -Mode $Mode\n'
                '$childCode = $LASTEXITCODE\n'
                'if ($env:PATH -cne $beforePath -or (Get-Location).Path -cne $beforeLocation) { exit 99 }\n'
                'exit $childCode\n', encoding='ascii',
            )
            for mode, expected in [('Preflight', '--preflight'), ('Assets', '--assets-only'), ('All', '')]:
                with self.subTest(mode=mode):
                    env = os.environ.copy()
                    env['EXPECTED_MODE'] = expected
                    result = subprocess.run(
                        ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                         '-File', str(driver), '-BashPath', str(bash), '-Mode', mode],
                        env=env, capture_output=True, text=True, timeout=30,
                    )
                    self.assertEqual(result.returncode, 23, result.stderr)


if __name__ == '__main__':
    unittest.main()
