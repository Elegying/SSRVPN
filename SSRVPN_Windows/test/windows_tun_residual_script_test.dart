import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/services/windows_tun_runtime_probe.dart';
import 'package:ssrvpn_windows/src/services/windows_powershell.dart';

void main() {
  const existing =
      (index: 7, interfaceGuid: '11111111-1111-4111-8111-111111111111');
  const unrelated =
      (index: 8, interfaceGuid: '22222222-2222-4222-8222-222222222222');

  Future<ProcessResult> runSnapshot(String script, {bool dual = true}) {
    // Execute the production PowerShell against inert snapshots. No adapter,
    // route, registry or currently running client is modified by this fixture.
    final fixture = '''
function Get-NetAdapter {
  param([switch]\$IncludeHidden)
  [pscustomobject]@{ifIndex=7; InterfaceGuid='${existing.interfaceGuid}'}
}
function Get-NetIPAddress {
  [pscustomobject]@{InterfaceIndex=7; IPAddress='198.18.0.1'}
  ${dual ? "[pscustomobject]@{InterfaceIndex=7; IPAddress='fdfe:dcba:9876::1'}" : ''}
}
function Get-NetRoute {
  [pscustomobject]@{InterfaceIndex=7; DestinationPrefix='0.0.0.0/1'}
  [pscustomobject]@{InterfaceIndex=7; DestinationPrefix='128.0.0.0/1'}
}
''';
    return TimedProcessRunner.run(
        windowsPowerShellExecutable(),
        [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          windowsPowerShellUtf8Script('$fixture\n$script'),
        ],
        timeout: const Duration(seconds: 10));
  }

  for (final dual in [false, true]) {
    test('production residual script excludes preexisting TUN dual=$dual',
        () async {
      final result = await probeWindowsTunResidual(
        baselineInterfaces: const {existing},
        scriptRunner: (script) => runSnapshot(script, dual: dual),
      );
      expect(result.status, WindowsTunResidualStatus.gone);
      expect(result.interfaces, isEmpty);
    }, skip: !Platform.isWindows);
  }

  test('production residual script still detects a newly created TUN',
      () async {
    final result = await probeWindowsTunResidual(
      baselineInterfaces: const {unrelated},
      scriptRunner: runSnapshot,
    );
    expect(result.status, WindowsTunResidualStatus.present);
    expect(result.interfaces, const {existing});
  }, skip: !Platform.isWindows);

  test('reused interface index does not hide a new interface identity',
      () async {
    final result = await probeWindowsTunResidual(
      baselineInterfaces: {(index: 7, interfaceGuid: unrelated.interfaceGuid)},
      scriptRunner: runSnapshot,
    );
    expect(result.status, WindowsTunResidualStatus.present);
  }, skip: !Platform.isWindows);

  test('changed interface index does not steal a preexisting identity',
      () async {
    final result = await probeWindowsTunResidual(
      baselineInterfaces: {(index: 9, interfaceGuid: existing.interfaceGuid)},
      scriptRunner: runSnapshot,
    );
    expect(result.status, WindowsTunResidualStatus.gone);
  }, skip: !Platform.isWindows);

  test('explicit owned identity remains subject to teardown checks', () async {
    final result = await probeWindowsTunResidual(
      expectedInterfaces: const {existing},
      baselineInterfaces: const {existing},
      scriptRunner: runSnapshot,
    );
    expect(result.status, WindowsTunResidualStatus.present);
    expect(result.interfaces, const {existing});
  }, skip: !Platform.isWindows);

  test('legacy discovery still requires and detects the full signature',
      () async {
    for (final dual in [false, true]) {
      final result = await probeWindowsTunResidual(
        baselineInterfaces: const {existing},
        discoverLegacySignatures: true,
        scriptRunner: (script) => runSnapshot(script, dual: dual),
      );
      expect(
          result.status,
          dual
              ? WindowsTunResidualStatus.present
              : WindowsTunResidualStatus.gone);
    }
  }, skip: !Platform.isWindows);
}
