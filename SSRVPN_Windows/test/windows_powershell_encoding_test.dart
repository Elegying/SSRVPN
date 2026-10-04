import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/src/services/windows_powershell.dart';

void main() {
  test('PowerShell ignores caller module search paths', () async {
    final root = await Directory.systemTemp.createTemp('ssrvpn-ps-modules-');
    addTearDown(() => root.delete(recursive: true));
    final result = await TimedProcessRunner.run(
      windowsPowerShellExecutable(),
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        windowsPowerShellUtf8Script(r'''
if ($env:PSModulePath -cne ($PSHOME + '\Modules')) { throw 'Unexpected module search path' }
$utility = Get-Command ConvertTo-Json -ErrorAction Stop
if (-not $utility.Module.Path.StartsWith($PSHOME + '\Modules\', [StringComparison]::OrdinalIgnoreCase)) {
  throw 'Utility module escaped the Windows PowerShell installation'
}
Write-Output 'system-modules-ok'
''')
      ],
      environment: {'PSModulePath': root.path},
      timeout: const Duration(seconds: 30),
    );
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stdout.toString().trim(), 'system-modules-ok');
  }, skip: !Platform.isWindows);

  test(
    'Windows PowerShell 5.1 output reaches Dart as UTF-8',
    () async {
      final result = await TimedProcessRunner.run(
        windowsPowerShellExecutable(),
        <String>[
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          windowsPowerShellUtf8Script("Write-Output '中文代理恢复成功'"),
        ],
        // This verifies encoding, not cold-start performance. Windows
        // PowerShell 5.1 can take over 10 seconds to start on a loaded runner.
        timeout: const Duration(seconds: 30),
      );

      expect(result.exitCode, 0);
      expect(result.stdout.toString().trim(), '中文代理恢复成功');
    },
    skip: !Platform.isWindows,
  );
}
