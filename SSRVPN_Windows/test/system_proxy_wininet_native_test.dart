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
$path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$key = Get-Item -LiteralPath $path
$hadAutoDetect = $key.GetValueNames() -contains 'AutoDetect'
$autoDetect = $key.GetValue('AutoDetect')
$kind = if ($hadAutoDetect) { $key.GetValueKind('AutoDetect') } else { $null }
try {
  # Reproduce UI-enabled WPAD with an absent legacy DWORD.
  [SsrvpnConnectionFlags]::Write([uint32](($original -band 7) -bor 8))
  Remove-ItemProperty -LiteralPath $path -Name AutoDetect -ErrorAction SilentlyContinue
  $before = [SsrvpnConnectionFlags]::Read()
  if (($before -band 8) -eq 0) { throw 'Fixture did not retain UI auto-detect' }
  Set-ItemProperty -LiteralPath $path -Name AutoDetect -Type DWord -Value 0
  [SsrvpnConnectionFlags]::Write(3)
  if (([SsrvpnConnectionFlags]::Read() -band 8) -ne 0) { throw 'Proxy did not acquire flags' }
  Remove-ItemProperty -LiteralPath $path -Name AutoDetect -ErrorAction SilentlyContinue
  [SsrvpnConnectionFlags]::Write($before)
  if ([SsrvpnConnectionFlags]::Read() -ne $before) { throw 'Disconnect did not restore flags' }
} finally {
  if ($hadAutoDetect) { $key.SetValue('AutoDetect', $autoDetect, $kind) }
  else { $key.DeleteValue('AutoDetect', $false) }
  [SsrvpnConnectionFlags]::Write($original)
  $key.Dispose()
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
