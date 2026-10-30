import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/system_proxy_service.dart';

Map<String, Object> _snapshot({bool owned = false}) => {
      'hasProxyEnable': true,
      'proxyEnable': owned ? 1 : 0,
      'hasProxyServer': owned,
      'proxyServer': owned ? '127.0.0.1:7890' : '',
      'hasProxyOverride': false,
      'proxyOverride': '',
      'hasAutoConfigUrl': false,
      'autoConfigUrl': '',
      'hasAutoDetect': false,
      'autoDetect': 0,
      'connectionFlags': owned ? 3 : 1,
    };

void main() {
  test('native guardian checks each time and rejects non-boolean results',
      () async {
    var calls = 0;
    Object? reply = true;
    final service = SystemProxyService.forTesting(
      isWindows: true,
      nativeGuardian: () async {
        calls++;
        return reply;
      },
      scriptRunner: (_) async =>
          throw StateError('Read-only probe spawned PowerShell'),
    );
    expect(await service.isLauncherGuardianReady(), isTrue);
    for (final invalid in <Object?>[false, null, 1, 'true', {}]) {
      reply = invalid;
      expect(await service.isLauncherGuardianReady(), isFalse);
    }
    reply = true;
    expect(await service.isLauncherGuardianReady(), isTrue);
    expect(calls, 7);
  });

  test('native guardian failure and cancellation stay fail closed', () async {
    final entered = Completer<void>();
    final pending = Completer<Object?>();
    final cancellation = Completer<void>();
    var fail = false;
    final service = SystemProxyService.forTesting(
      isWindows: true,
      nativeGuardian: () {
        if (fail) throw StateError('bridge unavailable');
        entered.complete();
        return pending.future;
      },
      scriptRunner: (_) async =>
          throw StateError('Unexpected PowerShell fallback'),
    );
    final checking =
        service.isLauncherGuardianReady(cancellation: cancellation.future);
    await entered.future;
    cancellation.complete();
    expect(await checking.timeout(const Duration(seconds: 1)), isFalse);
    pending.complete(true);
    fail = true;
    expect(await service.isLauncherGuardianReady(), isFalse);
  });

  test('native preflight and verification leave exactly three write children',
      () async {
    final dir = await Directory.systemTemp.createTemp('ssrvpn-native-read-');
    addTearDown(() => dir.delete(recursive: true));
    final checks = <bool>[];
    final scripts = <String>[];
    var owned = false;
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: dir.path,
      nativeSnapshot: (guardian) async {
        checks.add(guardian);
        return {'status': 0, 'snapshot': _snapshot(owned: owned)};
      },
      scriptRunner: (script) async {
        scripts.add(script);
        expect(script, isNot(contains('ConvertTo-Json -Compress')));
        if (script.contains('[SsrvpnConnectionFlags]::Write([uint32](3))')) {
          owned = true;
        }
        return ProcessResult(1, 0, '', '');
      },
    );
    await service.initialize(dir.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isTrue);
    expect(checks, [true, false]);
    expect(scripts, hasLength(3));
    expect(scripts[0], contains('-Name Valid -Type DWord -Value 1'));
    expect(scripts[0], contains("-Name 'SSRVPNProxyRecovery'"));
    expect(scripts[1], contains('[SsrvpnConnectionFlags]::Write([uint32](3))'));
    expect(scripts[2],
        contains('-Name ActivationInProgress -Type DWord -Value 0'));
    final saved = jsonDecode(
        await File('${dir.path}/SSRVPN/runtime/system_proxy_backup.json')
            .readAsString()) as Map;
    expect(saved['connectionFlags'], 1);
    expect(saved['_activationInProgress'], isFalse);
    expect(
        service.lastAcquisitionTiming,
        matches(
            r'^preflight=\d+ms, prepare=\d+ms, apply=\d+ms, commit=\d+ms, verify=\d+ms$'));
  });

  test('failed native verification rolls back the acquired endpoint', () async {
    final dir = await Directory.systemTemp.createTemp('ssrvpn-native-verify-');
    addTearDown(() => dir.delete(recursive: true));
    var owned = false;
    var restored = false;
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: dir.path,
      nativeSnapshot: (guardian) async =>
          guardian ? {'status': 0, 'snapshot': _snapshot()} : {'status': 3},
      scriptRunner: (script) async {
        if (script.contains("[Console]::Out.Write('TERMINAL')")) {
          return ProcessResult(1, 0, 'TERMINAL', '');
        }
        if (script.contains('ConvertTo-Json -Compress')) {
          return ProcessResult(1, 0, jsonEncode(_snapshot(owned: owned)), '');
        }
        if (script.contains('[SsrvpnConnectionFlags]::Write([uint32](3))')) {
          owned = true;
        }
        if (script
            .contains('-Name EndpointRestoreInProgress -Type DWord -Value 1')) {
          owned = false;
          restored = true;
        }
        return ProcessResult(1, 0, '', '');
      },
    );
    await service.initialize(dir.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isFalse);
    expect(restored, isTrue);
    expect(owned, isFalse);
    expect(service.isProxyEnabled, isFalse);
    expect(service.recoveryPending, isFalse);
    expect(
        File('${dir.path}/SSRVPN/runtime/system_proxy_backup.json')
            .existsSync(),
        isFalse);
  });

  final invalid = <Object?>[
    null,
    {},
    {'status': '0'},
    {'status': 1},
    {'status': 2},
    {'status': 3},
    {'status': 99},
    {'status': 0},
    {'status': 0, 'snapshot': _snapshot()..remove('hasProxyEnable')},
    {'status': 0, 'snapshot': _snapshot()..remove('connectionFlags')},
    {'status': 0, 'snapshot': _snapshot()..['connectionFlags'] = 16},
    {'status': 0, 'snapshot': _snapshot()..['proxyEnable'] = '1'},
  ];
  for (var i = 0; i < invalid.length; i++) {
    test('native read failure $i refuses acquisition without writes', () async {
      final dir =
          await Directory.systemTemp.createTemp('ssrvpn-native-denied-');
      addTearDown(() => dir.delete(recursive: true));
      var writes = 0;
      final service = SystemProxyService.forTesting(
        isWindows: true,
        localAppData: dir.path,
        nativeSnapshot: (_) async => invalid[i],
        scriptRunner: (_) async {
          writes++;
          return ProcessResult(1, 0, '', '');
        },
      );
      await service.initialize(dir.path);
      expect(await service.setSystemProxy('127.0.0.1', 7890), isFalse);
      expect(writes, 0);
      expect(service.isProxyEnabled, isFalse);
      expect(service.lastError, isNotNull);
      expect(
          File('${dir.path}/SSRVPN/runtime/system_proxy_backup.json')
              .existsSync(),
          isFalse);
    });
  }

  test('native read exception and late cancelled result never authorize writes',
      () async {
    final dir = await Directory.systemTemp.createTemp('ssrvpn-native-cancel-');
    addTearDown(() => dir.delete(recursive: true));
    final entered = Completer<void>();
    final pending = Completer<Object?>();
    final cancellation = Completer<void>();
    var throwRead = false;
    var writes = 0;
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: dir.path,
      nativeSnapshot: (_) {
        if (throwRead) throw StateError('native unavailable');
        entered.complete();
        return pending.future;
      },
      scriptRunner: (_) async {
        writes++;
        return ProcessResult(1, 0, '', '');
      },
    );
    await service.initialize(dir.path);
    final acquisition = service.setSystemProxy('127.0.0.1', 7890,
        cancellation: cancellation.future);
    await entered.future;
    cancellation.complete();
    expect(await acquisition.timeout(const Duration(seconds: 1)), isFalse);
    pending.complete({'status': 0, 'snapshot': _snapshot()});
    throwRead = true;
    expect(await service.setSystemProxy('127.0.0.1', 7890), isFalse);
    expect(writes, 0);
    expect(service.recoveryPending, isFalse);
  });
}
