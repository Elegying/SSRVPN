import 'dart:convert';
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

  Future<ProcessResult> runBaseline(String script, {bool active = false}) {
    final fixture = '''
function Get-NetAdapter {
  param([switch]\$IncludeHidden)
  [pscustomobject]@{ifIndex=7; InterfaceGuid='${existing.interfaceGuid}'}
  [pscustomobject]@{ifIndex=8; InterfaceGuid='${unrelated.interfaceGuid}'}
}
function Get-NetIPAddress {
  [pscustomobject]@{InterfaceIndex=8; IPAddress='192.0.2.8'}
  ${active ? "[pscustomobject]@{InterfaceIndex=7; IPAddress='198.18.0.1'}" : ''}
}
function Get-NetRoute {
  [pscustomobject]@{InterfaceIndex=8; DestinationPrefix='192.0.2.0/24'}
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

  test('startup baseline cannot exempt an empty TUN reused with the same GUID',
      () async {
    final baseline = await probeWindowsNetworkInterfaceIdentities(
      includeEmptyAdapters: false,
      scriptRunner: runBaseline,
    );
    expect(baseline, const {unrelated});
    final captured =
        selectWindowsTunInterfacesCreatedAfter(const {existing}, baseline);
    expect(captured, const {existing});
    // Also cover an early crash before owned identities could be persisted.
    final residual = await probeWindowsTunResidual(
      baselineInterfaces: baseline,
      scriptRunner: runSnapshot,
    );
    expect(residual.status, WindowsTunResidualStatus.present);
    expect(residual.interfaces, const {existing});
  }, skip: !Platform.isWindows);

  test('startup baseline still exempts an already active external TUN',
      () async {
    final baseline = await probeWindowsNetworkInterfaceIdentities(
      includeEmptyAdapters: false,
      scriptRunner: (script) => runBaseline(script, active: true),
    );
    expect(baseline, const {existing, unrelated});
    final residual = await probeWindowsTunResidual(
      baselineInterfaces: baseline,
      scriptRunner: runSnapshot,
    );
    expect(residual.status, WindowsTunResidualStatus.gone);
  }, skip: !Platform.isWindows);

  test('old baseline-only markers cannot hide a reopened TUN on upgrade',
      () async {
    final old = decodeWindowsTunTeardownMarker(jsonEncode({
      'version': 2,
      'interfaces': <Object>[],
      'baselineInterfaces': [
        {'index': existing.index, 'guid': existing.interfaceGuid},
      ],
    }))!;
    final gate = WindowsTunTeardownGate()
      ..markPending(old.interfaces, old.baselineInterfaces,
          old.baselineIncludesEmptyAdapters);
    expect(gate.baselineIncludesEmptyAdapters, isTrue);
    final result = await probeWindowsTunResidual(
      baselineInterfaces: gate.baselineInterfaces,
      baselineIncludesEmptyAdapters: gate.baselineIncludesEmptyAdapters,
      scriptRunner: (script) => runSnapshot(script, dual: false),
    );
    expect(result.status, WindowsTunResidualStatus.present);
    gate.observe(result);
    expect(gate.interfaces, const {existing});
    expect(
        gate.accept((
          status: WindowsTunResidualStatus.gone,
          interfaces: const <WindowsTunInterfaceIdentity>{}
        )),
        isTrue);
    expect(gate.baselineIncludesEmptyAdapters, isFalse);
    final fresh = decodeWindowsTunTeardownMarker(encodeWindowsTunTeardownMarker(
        const {},
        baselineInterfaces: const {unrelated}))!;
    expect(fresh.baselineIncludesEmptyAdapters, isFalse);
  }, skip: !Platform.isWindows);

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
