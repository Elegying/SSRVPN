import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/services/windows_tun_runtime_probe.dart';
import 'package:ssrvpn_windows/src/services/windows_powershell.dart';

void main() {
  const owned =
      (index: 7, interfaceGuid: '11111111-1111-4111-8111-111111111111');
  const foreign =
      (index: 8, interfaceGuid: '22222222-2222-4222-8222-222222222222');

  Map<String, Object> adapter(WindowsTunInterfaceIdentity identity) => {
        'ifIndex': identity.index,
        'InterfaceGuid': identity.interfaceGuid,
      };
  Map<String, Object> address(int index, String value) =>
      {'InterfaceIndex': index, 'IPAddress': value};
  Map<String, Object> route(int index) =>
      {'InterfaceIndex': index, 'DestinationPrefix': '0.0.0.0/1'};

  String marker(
      {int version = 3, bool known = true, bool oldBaseline = false}) {
    // Exercise the application's real writer, not a hand-maintained copy of
    // its wire format. A future schema change must reach the installer too.
    final value = encodeWindowsTunTeardownMarker(
      known ? {owned} : {},
      baselineInterfaces: oldBaseline ? {owned, foreign} : {foreign},
    );
    if (version == 3) return value;
    final decoded = jsonDecode(value) as Map<String, dynamic>;
    decoded['version'] = version;
    return jsonEncode(decoded);
  }

  Future<ProcessResult> probe({
    required String markerText,
    String mode = 'ownership',
    List<Map<String, Object>> adapters = const [],
    List<Map<String, Object>> addresses = const [],
    List<Map<String, Object>> routes = const [],
    List<Object> clearProbes = const [],
    bool capturedBeforeStop = false,
  }) {
    final helper =
        File('installer/tun_ownership.ps1').absolute.path.replaceAll("'", "''");
    final data = base64Encode(utf8.encode(jsonEncode({
      'marker': markerText,
      'adapters': adapters,
      'addresses': addresses,
      'routes': routes,
      'clearProbes': clearProbes,
      'knownInterfaces': capturedBeforeStop
          ? [
              {
                'OriginalIndex': owned.index,
                'ExpectedGuid': owned.interfaceGuid
              }
            ]
          : <Map<String, Object>>[],
    })));
    // Only the packaged predicates run. Every host network/file-state query
    // is replaced with an inert snapshot; no client, adapter or proxy changes.
    final script = '''
\$ErrorActionPreference = 'Stop'
. '$helper'
\$fixture = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$data')) | ConvertFrom-Json
\$InstalledCorePidPath = 'C:\\ssrvpn-inert-fixture\\mihomo.pid'
function Test-Path {
  param([string]\$LiteralPath, [string]\$PathType)
  if (\$LiteralPath -ne 'C:\\ssrvpn-inert-fixture\\tun_teardown.pending') { throw 'Unexpected path query' }
  return \$PathType -ne 'Container'
}
function Get-Content { param([string]\$LiteralPath, [string]\$Encoding, [switch]\$Raw); return \$fixture.marker }
function Get-NetAdapter { param([switch]\$IncludeHidden); return \$fixture.adapters }
function Get-NetIPAddress { return \$fixture.addresses }
function Get-NetRoute { return \$fixture.routes }
function Stop-Process { throw 'Host process mutation is forbidden' }
function Set-ItemProperty { throw 'Host registry mutation is forbidden' }
function Remove-NetRoute { throw 'Host route mutation is forbidden' }
\$ownership = @(Get-SsrvpnTunOwnership -KnownInterfaces @(\$fixture.knownInterfaces))
if ('$mode' -eq 'wait') {
  \$script:probeCount = 0
  function Test-SsrvpnTunArtifactsRemoved {
    param([object[]]\$OwnedInterfaces)
    \$value = \$fixture.clearProbes[[Math]::Min(\$script:probeCount, \$fixture.clearProbes.Count - 1)]
    \$script:probeCount++
    if (\$value -is [string]) { throw 'Injected network probe failure' }
    return \$value
  }
  \$removed = Wait-SsrvpnTunTeardown -OwnedInterfaces \$ownership -TimeoutMilliseconds 1500
  @{ removed = \$removed; probes = \$script:probeCount } | ConvertTo-Json -Compress
} elseif ('$mode' -eq 'removed') {
  if (\$ownership.Count -eq 0) { 'true' } else {
    Test-SsrvpnTunArtifactsRemoved -OwnedInterfaces \$ownership | ConvertTo-Json -Compress
  }
} else {
  ConvertTo-Json -InputObject \$ownership -Compress
}
''';
    return TimedProcessRunner.run(
      windowsPowerShellExecutable(),
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        windowsPowerShellUtf8Script(script)
      ],
      timeout: const Duration(seconds: 12),
    );
  }

  void successful(ProcessResult result) =>
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

  group('packaged installer TUN contract', () {
    for (final version in [1, 2, 3]) {
      test('accepts client ownership schema $version', () async {
        final result = await probe(markerText: marker(version: version));
        successful(result);
        final identities = jsonDecode(result.stdout as String) as List;
        expect(identities, [
          {'OriginalIndex': owned.index, 'ExpectedGuid': owned.interfaceGuid}
        ]);
      });
    }

    test('rejects an unknown future marker format', () async {
      final result = await probe(markerText: marker(version: 99));
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('unsupported schema'));
    });

    test('empty phantom adapter does not block an upgrade forever', () async {
      final result = await probe(
          markerText: marker(version: 2),
          mode: 'removed',
          adapters: [adapter(owned)]);
      successful(result);
      expect((result.stdout as String).trim(), 'true');
    });

    for (final addressOnly in [true, false]) {
      test('owned ${addressOnly ? 'address' : 'route'} still blocks teardown',
          () async {
        final result = await probe(
            markerText: marker(version: 2),
            mode: 'removed',
            adapters: [adapter(owned)],
            addresses: addressOnly ? [address(7, '198.18.0.1')] : [],
            routes: addressOnly ? [] : [route(7)]);
        successful(result);
        expect((result.stdout as String).trim(), 'false');
      });
    }

    test('a recycled interface index does not steal a foreign adapter',
        () async {
      final result = await probe(
          markerText: marker(version: 2),
          mode: 'removed',
          adapters: [adapter((index: 7, interfaceGuid: foreign.interfaceGuid))],
          addresses: [address(7, '192.0.2.7')],
          routes: [route(7)]);
      successful(result);
      expect((result.stdout as String).trim(), 'true');
    });

    test('orphan routes on the original owned index still block teardown',
        () async {
      final result = await probe(
          markerText: marker(version: 2), mode: 'removed', routes: [route(7)]);
      successful(result);
      expect((result.stdout as String).trim(), 'false');
    });

    test('known GUID is followed when its interface index changes', () async {
      final result = await probe(
          markerText: marker(version: 2),
          mode: 'removed',
          adapters: [adapter((index: 9, interfaceGuid: owned.interfaceGuid))],
          addresses: [address(9, '198.18.0.1')]);
      successful(result);
      expect((result.stdout as String).trim(), 'false');
    });

    test('v2 baseline-only marker cannot exempt a reopened empty adapter',
        () async {
      final result = await probe(
          markerText: marker(version: 2, known: false, oldBaseline: true),
          adapters: [
            adapter(owned)
          ],
          addresses: [
            address(7, '198.18.0.1'),
            address(7, 'fdfe:dcba:9876::1')
          ],
          routes: [
            route(7)
          ]);
      successful(result);
      expect(jsonDecode(result.stdout as String), isNotEmpty);
    });

    test('v3 baseline-only marker still excludes an already active foreign VPN',
        () async {
      final result = await probe(
          markerText: marker(known: false, oldBaseline: true),
          adapters: [
            adapter(owned)
          ],
          addresses: [
            address(7, '198.18.0.1'),
            address(7, 'fdfe:dcba:9876::1')
          ],
          routes: [
            route(7)
          ]);
      successful(result);
      expect(jsonDecode(result.stdout as String), isEmpty);
    });

    test('v3 baseline detects partially created TUN with a single address',
        () async {
      final result = await probe(
          markerText: marker(known: false),
          adapters: [adapter(owned)],
          addresses: [address(7, '198.18.0.1')]);
      successful(result);
      expect(jsonDecode(result.stdout as String), isNotEmpty);
    });

    test('v3 baseline detects an IPv6-only partial TUN', () async {
      final result = await probe(
          markerText: marker(known: false),
          adapters: [adapter(owned)],
          addresses: [address(7, 'fdfe:dcba:9876::1')]);
      successful(result);
      expect(jsonDecode(result.stdout as String), isNotEmpty);
    });

    test('baseline discovers a new route-only TUN', () async {
      final result = await probe(
          markerText: marker(known: false),
          adapters: [adapter(owned)],
          routes: [route(7)]);
      successful(result);
      expect(jsonDecode(result.stdout as String), isNotEmpty);
    });

    test('unidentified post-start orphan route fails closed', () async {
      final result =
          await probe(markerText: marker(known: false), routes: [route(7)]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr,
          contains('route remains without a verifiable interface identity'));
    });

    test('pre-stop GUID survives a baseline-only reread during teardown',
        () async {
      final result = await probe(
        markerText: marker(known: false),
        capturedBeforeStop: true,
        mode: 'removed',
        routes: [route(7)],
      );
      successful(result);
      expect((result.stdout as String).trim(), 'false');
    });

    test('baseline orphan route on a preexisting index remains foreign',
        () async {
      final result =
          await probe(markerText: marker(known: false), routes: [route(8)]);
      successful(result);
      expect(jsonDecode(result.stdout as String), isEmpty);
    });

    test('explicit ownership cannot expand to an unrelated new VPN', () async {
      const other =
          (index: 10, interfaceGuid: '33333333-3333-4333-8333-333333333333');
      final result = await probe(markerText: marker(version: 2), adapters: [
        adapter(other)
      ], addresses: [
        address(10, '198.18.0.1'),
        address(10, 'fdfe:dcba:9876::1')
      ], routes: [
        route(10)
      ]);
      successful(result);
      expect(jsonDecode(result.stdout as String), [
        {'OriginalIndex': owned.index, 'ExpectedGuid': owned.interfaceGuid}
      ]);
    });

    for (final legacy in ['pending', '7']) {
      test('legacy $legacy still requires the complete live signature',
          () async {
        final result = await probe(
            markerText: legacy,
            adapters: [adapter(owned)],
            addresses: [address(7, '198.18.0.1')],
            routes: [route(7)]);
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('strict SSRVPN signature'));
      });
    }

    for (final interruption in [false, 'error']) {
      test('teardown needs consecutive clear probes after $interruption',
          () async {
        final result = await probe(
            markerText: marker(),
            mode: 'wait',
            clearProbes: [true, interruption, true, true]);
        successful(result);
        expect(jsonDecode(result.stdout as String),
            {'removed': true, 'probes': 4});
      });
    }

    test('persistent residual reaches the bounded timeout', () async {
      final result =
          await probe(markerText: marker(), mode: 'wait', clearProbes: [false]);
      successful(result);
      final output = jsonDecode(result.stdout as String) as Map;
      expect(output['removed'], false);
      expect(output['probes'], greaterThan(1));
    });
  }, skip: !Platform.isWindows);
}
