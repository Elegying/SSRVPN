import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/services/system_proxy_service.dart';
import 'package:ssrvpn_windows/src/services/windows_powershell.dart';

void main() {
  // WinINet escapes RegOverridePredefKey. Run this integration check only on
  // disposable hosted CI, never on a developer/user's live LAN settings.
  final hosted = Platform.isWindows &&
      Platform.environment['GITHUB_ACTIONS'] == 'true' &&
      Platform.environment['RUNNER_ENVIRONMENT'] == 'github-hosted' &&
      Platform.environment['GITHUB_REPOSITORY'] == 'Elegying/SSRVPN';
  test('WinINet interop reads and restores the real LAN auto-detect flag',
      () async {
    final result = await TimedProcessRunner.run(
      windowsPowerShellExecutable(),
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        windowsPowerShellUtf8Script(windowsProxyFlagsInterop +
            r'''
$original = [SsrvpnConnectionFlags]::Read()
try {
  $changed = $original -bxor 8
  [SsrvpnConnectionFlags]::Write([uint32]$changed)
  if ([SsrvpnConnectionFlags]::Read() -ne $changed) { throw 'LAN flag did not change' }
} finally {
  [SsrvpnConnectionFlags]::Write($original)
}
if ([SsrvpnConnectionFlags]::Read() -ne $original) { throw 'LAN flag did not restore' }
'LAN_FLAGS_RESTORED'
'''),
      ],
      timeout: const Duration(seconds: 20),
    );
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(result.stdout.toString().trim(), 'LAN_FLAGS_RESTORED');
  }, skip: hosted ? false : 'Real LAN mutations require disposable Windows CI');
}
