import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/src/services/windows_powershell.dart';

void main() {
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
