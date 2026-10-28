import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/system_proxy_service.dart';

const bypass = '<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;'
    '172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;'
    '172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*';
Map<String, Object> snapshot({required int flags, bool owned = false}) => {
      'hasProxyEnable': true, 'proxyEnable': owned ? 1 : 0,
      'hasProxyServer': owned, 'proxyServer': owned ? '127.0.0.1:7890' : '',
      'hasProxyOverride': owned, 'proxyOverride': owned ? bypass : '',
      // A stored PAC URL does not mean its checkbox was enabled.
      'hasAutoConfigUrl': !owned,
      'autoConfigUrl': owned ? '' : 'http://127.0.0.1:1080/pac',
      'hasAutoDetect': false, 'autoDetect': 0,
      'connectionFlags': flags,
    };

void main() {
  for (final flags in [1, 5, 9, 13]) {
    test('acquisition saves actual LAN flags $flags and restores them',
        () async {
      final dir = await Directory.systemTemp.createTemp('ssrvpn-lan-flags-');
      addTearDown(() => dir.delete(recursive: true));
      var live = snapshot(flags: flags);
      final writes = <String>[];
      final service = SystemProxyService.forTesting(
        isWindows: true,
        localAppData: dir.path,
        scriptRunner: (script) async {
          if (script.contains('ConvertTo-Json -Compress')) {
            expect(script, contains('[SsrvpnConnectionFlags]::Read()'));
            return ProcessResult(0, 0, jsonEncode(live), '');
          }
          writes.add(script);
          if (script.contains('[SsrvpnConnectionFlags]::Write([uint32](3))')) {
            live = snapshot(flags: 3, owned: true);
          }
          return ProcessResult(0, 0, '', '');
        },
      );
      await service.initialize(dir.path);
      expect(await service.setSystemProxy('127.0.0.1', 7890), isTrue);
      final file = File('${dir.path}/SSRVPN/runtime/system_proxy_backup.json');
      final backup = jsonDecode(await file.readAsString()) as Map;
      expect(backup['connectionFlags'], flags);
      expect(backup['hasAutoDetect'], isFalse);
      expect(writes.join('\n'),
          contains('OriginalConnectionFlags -Type DWord -Value $flags'));
      expect(await service.clearSystemProxy(), isTrue);
      final restoration = writes.singleWhere(
          (s) => s.contains('-Name RestoreInProgress -Type DWord -Value 1'));
      expect(restoration,
          contains('[SsrvpnConnectionFlags]::Write([uint32]($flags))'));
      expect(restoration.indexOf('[SsrvpnConnectionFlags]::Write'),
          lessThan(restoration.indexOf('-Name Valid -Type DWord -Value 0')));
      expect(file.existsSync(), isFalse);
    });
  }
  for (final legacy in [false, true]) {
    for (final endpointEnabled in [false, true]) {
      test(
          'startup preserves manual WPAD change legacy=$legacy endpoint=$endpointEnabled',
          () async {
        final dir = await Directory.systemTemp.createTemp('ssrvpn-wpad-edit-');
        addTearDown(() => dir.delete(recursive: true));
        final file =
            File('${dir.path}/SSRVPN/runtime/system_proxy_backup.json');
        await file.parent.create(recursive: true);
        final backup = snapshot(flags: 1)
          ..['_ownedProxyServer'] = '127.0.0.1:7890';
        if (legacy) backup.remove('connectionFlags');
        await file.writeAsString(jsonEncode(backup));
        final live = snapshot(flags: endpointEnabled ? 11 : 9, owned: true)
          ..['proxyEnable'] = endpointEnabled ? 1 : 0;
        final writes = <String>[];
        final service = SystemProxyService.forTesting(
          isWindows: true,
          localAppData: dir.path,
          scriptRunner: (script) async {
            if (script.contains('ConvertTo-Json -Compress')) {
              return ProcessResult(0, 0, jsonEncode(live), '');
            }
            if (script.contains("[Console]::Out.Write('TERMINAL')")) {
              return ProcessResult(0, 0, 'TERMINAL', '');
            }
            writes.add(script);
            return ProcessResult(0, 0, '', '');
          },
        );
        await service.initialize(dir.path);
        expect(service.recoveryPending, isFalse);
        expect(
            writes.any((s) =>
                s.contains('-Name RestoreInProgress -Type DWord -Value 1')),
            isFalse);
        expect(
            writes.any((s) => s.contains(r'-Path $regPath -Name AutoDetect')),
            isFalse);
        final endpoint = writes.where((s) =>
            s.contains('-Name EndpointRestoreInProgress -Type DWord -Value 1'));
        expect(endpoint.length, endpointEnabled ? 1 : 0);
        if (endpointEnabled) {
          expect(endpoint.single, contains(r'$ssrvpnPreservedFlags -band 13'));
        }
        expect(file.existsSync(), isFalse);
      });
    }
  }
  test(
      'failed LAN restore retains journal and core endpoint protection until retry',
      () async {
    final dir = await Directory.systemTemp.createTemp('ssrvpn-flags-retry-');
    addTearDown(() => dir.delete(recursive: true));
    var live = snapshot(flags: 9);
    var fail = true;
    final service = SystemProxyService.forTesting(
        isWindows: true,
        localAppData: dir.path,
        scriptRunner: (script) async {
          if (script.contains('ConvertTo-Json -Compress')) {
            return ProcessResult(0, 0, jsonEncode(live), '');
          }
          if (script.contains("[Console]::Out.Write('TERMINAL')")) {
            return ProcessResult(0, 0, 'FULL_RESTORE', '');
          }
          if (script.contains('[SsrvpnConnectionFlags]::Write([uint32](3))')) {
            live = snapshot(flags: 3, owned: true);
          }
          if (script.contains('-Name RestoreInProgress -Type DWord -Value 1')) {
            live = snapshot(flags: fail ? 3 : 9);
            if (fail) return ProcessResult(0, 1, '', 'WinINet write denied');
          }
          return ProcessResult(0, 0, '', '');
        });
    await service.initialize(dir.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isTrue);
    expect(await service.clearSystemProxy(), isFalse);
    expect(service.recoveryPending, isTrue);
    expect(service.endpointSafeWithPendingRecovery, isFalse);
    final backup = File('${dir.path}/SSRVPN/runtime/system_proxy_backup.json');
    expect(backup.existsSync(), isTrue);
    fail = false;
    expect(await service.clearSystemProxy(), isTrue);
    expect(service.recoveryPending, isFalse);
    expect(backup.existsSync(), isFalse);
  });
  test('invalid flags stop acquisition before any network mutation', () async {
    final dir = await Directory.systemTemp.createTemp('ssrvpn-bad-flags-');
    addTearDown(() => dir.delete(recursive: true));
    final service = SystemProxyService.forTesting(
        isWindows: true,
        localAppData: dir.path,
        scriptRunner: (script) async {
          if (script.contains('ConvertTo-Json -Compress')) {
            return ProcessResult(0, 0, jsonEncode(snapshot(flags: 16)), '');
          }
          expect(script, isNot(contains(r'-Path $regPath -Name ProxyServer')));
          return ProcessResult(0, 0, '', '');
        });
    await service.initialize(dir.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isFalse);
  });
}
