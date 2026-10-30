import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/system_proxy_service.dart';

Map<String, Object> _snapshot(String endpoint) => {
      'hasProxyEnable': true,
      'proxyEnable': endpoint.isEmpty ? 0 : 1,
      'hasProxyServer': endpoint.isNotEmpty,
      'proxyServer': endpoint,
      'hasProxyOverride': false,
      'proxyOverride': '',
      'hasAutoConfigUrl': false,
      'autoConfigUrl': '',
      'hasAutoDetect': false,
      'autoDetect': 0,
    };

void main() {
  test('five batches keep JSON before preparation and retain bounded timings',
      () async {
    final dir = await Directory.systemTemp.createTemp('ssrvpn-batches-');
    addTearDown(() => dir.delete(recursive: true));
    final backup = File('${dir.path}/SSRVPN/runtime/system_proxy_backup.json');
    final scripts = <String>[];
    var endpoint = '';
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: dir.path,
      scriptRunner: (script) async {
        scripts.add(script);
        if (script.contains('ConvertTo-Json -Compress')) {
          return ProcessResult(1, 0, jsonEncode(_snapshot(endpoint)), '');
        }
        if (script.contains('-Name Valid -Type DWord -Value 1')) {
          final saved = jsonDecode(await backup.readAsString()) as Map;
          expect(saved['_activationInProgress'], isTrue);
          expect(saved['_ownedProxyServer'], '127.0.0.1:7890');
          expect(script.indexOf('-Name Valid -Type DWord -Value 1'),
              lessThan(script.indexOf("-Name 'SSRVPNProxyRecovery'")));
        }
        if (script.contains('[SsrvpnConnectionFlags]::Write([uint32](3))')) {
          endpoint = '127.0.0.1:7890';
        }
        return ProcessResult(1, 0, '', '');
      },
    );
    await service.initialize(dir.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isTrue);
    expect(scripts, hasLength(5));
    expect(
        service.lastAcquisitionTiming,
        matches(r'^preflight=\d+ms, prepare=\d+ms, apply=\d+ms, '
            r'commit=\d+ms, verify=\d+ms$'));
    final originalTimings = service.lastAcquisitionTiming;
    expect(await service.isCurrentSystemProxyOwned(), isTrue);
    expect(service.lastAcquisitionTiming, originalTimings,
        reason:
            'Background ownership reads must not rewrite connection timing');
    scripts.clear();
    // Reacquiring the same endpoint retains the original recovery snapshot.
    expect(await service.setSystemProxy('127.0.0.1', 7890), isTrue);
    expect(scripts, hasLength(4));
    expect(service.lastAcquisitionTiming, isNot(contains('prepare=')));
    final saved = jsonDecode(await backup.readAsString()) as Map;
    expect(saved['proxyEnable'], 0);
    expect(saved['proxyServer'], '');
  });

  test('cancelled combined preflight cannot begin journal or proxy writes',
      () async {
    final dir = await Directory.systemTemp.createTemp('ssrvpn-preflight-');
    addTearDown(() => dir.delete(recursive: true));
    final entered = Completer<void>();
    final pending = Completer<ProcessResult>();
    final cancellation = Completer<void>();
    var calls = 0;
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: dir.path,
      scriptRunner: (script) {
        calls++;
        expect(script, contains('ProxySettingsPerUser'));
        expect(script, contains('SSRVPN_Windows_LauncherGuardian'));
        expect(script, contains('ConvertTo-Json -Compress'));
        expect(script, isNot(contains('Set-ItemProperty')));
        entered.complete();
        return pending.future;
      },
    );
    await service.initialize(dir.path);
    final acquisition = service.setSystemProxy('127.0.0.1', 7890,
        cancellation: cancellation.future);
    await entered.future;
    cancellation.complete();
    expect(await acquisition.timeout(const Duration(seconds: 1)), isFalse);
    expect(calls, 1);
    expect(service.recoveryPending, isFalse);
    expect(service.lastAcquisitionTiming, matches(r'^preflight=\d+ms$'));
    expect(
        File('${dir.path}/SSRVPN/runtime/system_proxy_backup.json')
            .existsSync(),
        isFalse);
    pending.complete(ProcessResult(1, 0, jsonEncode(_snapshot('')), ''));
  });
}
