import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart'
    show ProcessTerminationNotConfirmedException, SystemProxyOwnershipStatus;
import 'package:ssrvpn_windows/services/system_proxy_service.dart';

void main() {
  test('every PowerShell proxy operation forces UTF-8 output first', () async {
    final temp = await Directory.systemTemp.createTemp('ssrvpn_proxy_utf8_');
    addTearDown(() => temp.delete(recursive: true));
    final scripts = <String>[];
    var proxyReads = 0;
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        scripts.add(script);
        if (script.contains('ConvertTo-Json -Compress')) {
          proxyReads += 1;
          final connected = proxyReads > 1;
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'proxyEnable': connected ? 1 : 0,
              'hasProxyServer': true,
              'proxyServer': connected ? '127.0.0.1:7890' : '代理.example:8080',
              'hasProxyOverride': true,
              'proxyOverride': connected
                  ? '<local>;localhost;127.*;10.*;172.16.*;172.17.*;'
                      '172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;'
                      '172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;'
                      '172.28.*;172.29.*;172.30.*;172.31.*;192.168.*'
                  : '本地地址',
              'hasAutoConfigUrl': !connected,
              'autoConfigUrl': connected ? '' : 'https://例子.example/proxy.pac',
              'hasAutoDetect': true,
              'autoDetect': connected ? 0 : 1,
            }),
            '',
          );
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isTrue);

    expect(scripts, isNotEmpty);
    for (final script in scripts) {
      expect(script, startsWith(r"$ErrorActionPreference = 'Stop'"));
      expect(
        script,
        contains('[Console]::OutputEncoding = [Text.UTF8Encoding]::new'),
      );
      expect(script, contains(r'$OutputEncoding = [Console]::OutputEncoding'));
    }
  });

  test('proxy ownership reports owned, external change, and unavailable',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_proxy_ownership_status_',
    );
    addTearDown(() => temp.delete(recursive: true));
    var proxyReads = 0;
    var externallyChanged = false;
    var readable = true;
    const ownedOverride =
        '<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;'
        '172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;'
        '172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*';
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        if (!script.contains('ConvertTo-Json -Compress')) {
          return ProcessResult(1, 0, '', '');
        }
        proxyReads++;
        if (!readable) {
          return ProcessResult(1, 124, '', 'controlled read timeout');
        }
        final initialRead = proxyReads == 1;
        return ProcessResult(
          1,
          0,
          jsonEncode({
            'proxyEnable': initialRead ? 0 : 1,
            'hasProxyServer': !initialRead,
            'proxyServer': initialRead
                ? ''
                : externallyChanged
                    ? '127.0.0.1:8888'
                    : '127.0.0.1:7890',
            'hasProxyOverride': !initialRead,
            'proxyOverride': initialRead ? '' : ownedOverride,
            'hasAutoConfigUrl': false,
            'autoConfigUrl': '',
            'hasAutoDetect': true,
            'autoDetect': 0,
          }),
          '',
        );
      },
    );

    await service.initialize(temp.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isTrue);
    expect(
      await service.currentSystemProxyOwnershipStatus(),
      SystemProxyOwnershipStatus.owned,
    );

    externallyChanged = true;
    expect(
      await service.currentSystemProxyOwnershipStatus(),
      SystemProxyOwnershipStatus.externallyChanged,
    );

    readable = false;
    expect(
      await service.currentSystemProxyOwnershipStatus(),
      SystemProxyOwnershipStatus.unavailable,
    );
  });

  test('a transient startup read failure is retried before connecting',
      () async {
    final temp = await Directory.systemTemp.createTemp('ssrvpn_proxy_retry_');
    addTearDown(() => temp.delete(recursive: true));
    final runtime = Directory(
      '${temp.path}${Platform.pathSeparator}SSRVPN'
      '${Platform.pathSeparator}runtime',
    );
    await runtime.create(recursive: true);
    final backup = File(
      '${runtime.path}${Platform.pathSeparator}system_proxy_backup.json',
    );
    await backup.writeAsString(
      jsonEncode({
        'proxyEnable': 0,
        'hasProxyServer': false,
        'proxyServer': '',
        'hasProxyOverride': false,
        'proxyOverride': '',
        'hasAutoConfigUrl': false,
        'autoConfigUrl': '',
        'hasAutoDetect': false,
        'autoDetect': 0,
        '_ownedProxyServer': '127.0.0.1:7890',
        '_activationInProgress': false,
      }),
    );

    var reads = 0;
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        if (script.contains('ConvertTo-Json -Compress')) {
          reads += 1;
          if (reads == 1) {
            return ProcessResult(1, 124, '', 'temporary timeout');
          }
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'proxyEnable': 1,
              'hasProxyServer': true,
              'proxyServer': '127.0.0.1:7890',
              'hasProxyOverride': true,
              'proxyOverride':
                  '<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;'
                      '172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;'
                      '172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;'
                      '172.31.*;192.168.*',
              'hasAutoConfigUrl': false,
              'autoConfigUrl': '',
              'hasAutoDetect': true,
              'autoDetect': 0,
            }),
            '',
          );
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);
    expect(service.recoveryPending, isTrue);

    expect(await service.retryPendingRecovery(), isTrue);
    expect(service.recoveryPending, isFalse);
    expect(reads, 2);
    expect(await backup.exists(), isFalse);
  });

  test('stale activation restores only the exact owned endpoint', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_stale_activation_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final runtime = Directory(
      '${temp.path}${Platform.pathSeparator}SSRVPN'
      '${Platform.pathSeparator}runtime',
    );
    await runtime.create(recursive: true);
    final backup = File(
      '${runtime.path}${Platform.pathSeparator}system_proxy_backup.json',
    );
    await backup.writeAsString(
      jsonEncode({
        'proxyEnable': 0,
        'hasProxyServer': false,
        'proxyServer': '',
        'hasProxyOverride': false,
        'proxyOverride': '',
        'hasAutoConfigUrl': false,
        'autoConfigUrl': '',
        'hasAutoDetect': false,
        'autoDetect': 0,
        '_ownedProxyServer': '127.0.0.1:7890',
        '_activationInProgress': true,
      }),
    );
    final scripts = <String>[];
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        scripts.add(script);
        if (script.contains("[Console]::Out.Write('TERMINAL')")) {
          return ProcessResult(1, 0, 'TERMINAL', '');
        }
        if (script.contains('ConvertTo-Json -Compress')) {
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'proxyEnable': 1,
              'hasProxyServer': true,
              'proxyServer': '127.0.0.1:7890',
              'hasProxyOverride': true,
              'proxyOverride': 'user override',
              'hasAutoConfigUrl': true,
              'autoConfigUrl': 'https://user.example/proxy.pac',
              'hasAutoDetect': true,
              'autoDetect': 1,
            }),
            '',
          );
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);

    expect(
      scripts.any(
        (script) => script.contains(
          '-Name EndpointRestoreInProgress -Type DWord -Value 1',
        ),
      ),
      isTrue,
    );
    expect(
      scripts.any(
        (script) => script.contains(
          '-Name RestoreInProgress -Type DWord -Value 1',
        ),
      ),
      isFalse,
    );
    expect(await backup.exists(), isFalse);
    expect(service.recoveryPending, isFalse);
  });

  test('pending native activation resumes an exact interrupted prefix',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_native_activation_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final runtime = Directory(
      '${temp.path}${Platform.pathSeparator}SSRVPN'
      '${Platform.pathSeparator}runtime',
    );
    await runtime.create(recursive: true);
    final backup = File(
      '${runtime.path}${Platform.pathSeparator}system_proxy_backup.json',
    );
    await backup.writeAsString(
      jsonEncode({
        'proxyEnable': 0,
        'hasProxyServer': false,
        'proxyServer': '',
        'hasProxyOverride': false,
        'proxyOverride': '',
        'hasAutoConfigUrl': false,
        'autoConfigUrl': '',
        'hasAutoDetect': false,
        'autoDetect': 0,
        '_ownedProxyServer': '127.0.0.1:7890',
        '_activationInProgress': true,
      }),
    );
    final scripts = <String>[];
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        scripts.add(script);
        if (script.contains("[Console]::Out.Write('ACTIVATION')")) {
          return ProcessResult(1, 0, 'ACTIVATION', '');
        }
        if (script.contains("[Console]::Out.Write('pending')")) {
          return ProcessResult(1, 0, 'pending', '');
        }
        if (script.contains('ConvertTo-Json -Compress')) {
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'proxyEnable': 0,
              'hasProxyServer': true,
              'proxyServer': '127.0.0.1:7890',
              'hasProxyOverride': false,
              'proxyOverride': '',
              'hasAutoConfigUrl': false,
              'autoConfigUrl': '',
              'hasAutoDetect': false,
              'autoDetect': 0,
            }),
            '',
          );
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);

    expect(
      scripts.any(
        (script) => script.contains(
          '-Name RestoreInProgress -Type DWord -Value 1',
        ),
      ),
      isTrue,
    );
    expect(await backup.exists(), isFalse);
    expect(service.recoveryPending, isFalse);
  });

  test(
      'partial full restore resumes even when original endpoint matches target',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_partial_full_restore_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final runtime = Directory(
      '${temp.path}${Platform.pathSeparator}SSRVPN'
      '${Platform.pathSeparator}runtime',
    );
    await runtime.create(recursive: true);
    final backup = File(
      '${runtime.path}${Platform.pathSeparator}system_proxy_backup.json',
    );
    await backup.writeAsString(
      jsonEncode({
        'hasProxyEnable': true,
        'proxyEnable': 1,
        'hasProxyServer': true,
        'proxyServer': '127.0.0.1:7890',
        'hasProxyOverride': true,
        'proxyOverride': 'corp-bypass',
        'hasAutoConfigUrl': true,
        'autoConfigUrl': 'https://corp.example/proxy.pac',
        'hasAutoDetect': true,
        'autoDetect': 1,
        '_ownedProxyServer': '127.0.0.1:7890',
        '_activationInProgress': false,
      }),
    );
    final scripts = <String>[];
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        scripts.add(script);
        if (script.contains("[Console]::Out.Write('FULL_RESTORE')")) {
          return ProcessResult(1, 0, 'FULL_RESTORE', '');
        }
        if (script.contains('ConvertTo-Json -Compress')) {
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'hasProxyEnable': true,
              'proxyEnable': 1,
              'hasProxyServer': true,
              'proxyServer': '127.0.0.1:7890',
              'hasProxyOverride': true,
              'proxyOverride': 'corp-bypass',
              'hasAutoConfigUrl': false,
              'autoConfigUrl': '',
              'hasAutoDetect': true,
              'autoDetect': 0,
            }),
            '',
          );
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);

    expect(
      scripts.where(
        (script) =>
            script.contains('-Name RestoreInProgress -Type DWord -Value 1'),
      ),
      hasLength(1),
    );
    expect(
      scripts.where(
        (script) =>
            script.contains('EndpointRestoreInProgress -Type DWord -Value 1'),
      ),
      isEmpty,
    );
    expect(await backup.exists(), isFalse);
    expect(service.recoveryPending, isFalse);
  });

  test('partial endpoint restore resumes the endpoint-only transaction',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_partial_endpoint_restore_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final runtime = Directory(
      '${temp.path}${Platform.pathSeparator}SSRVPN'
      '${Platform.pathSeparator}runtime',
    );
    await runtime.create(recursive: true);
    final backup = File(
      '${runtime.path}${Platform.pathSeparator}system_proxy_backup.json',
    );
    await backup.writeAsString(
      jsonEncode({
        'hasProxyEnable': true,
        'proxyEnable': 0,
        'hasProxyServer': true,
        'proxyServer': 'corp.example:8080',
        'hasProxyOverride': true,
        'proxyOverride': 'corp-bypass',
        'hasAutoConfigUrl': true,
        'autoConfigUrl': 'https://corp.example/proxy.pac',
        'hasAutoDetect': true,
        'autoDetect': 1,
        '_ownedProxyServer': '127.0.0.1:7890',
        '_activationInProgress': false,
      }),
    );
    final scripts = <String>[];
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        scripts.add(script);
        if (script.contains("[Console]::Out.Write('ENDPOINT_RESTORE')")) {
          return ProcessResult(1, 0, 'ENDPOINT_RESTORE', '');
        }
        if (script.contains('ConvertTo-Json -Compress')) {
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'hasProxyEnable': true,
              'proxyEnable': 0,
              'hasProxyServer': true,
              'proxyServer': '127.0.0.1:7890',
              'hasProxyOverride': true,
              'proxyOverride': 'user-updated-bypass',
              'hasAutoConfigUrl': true,
              'autoConfigUrl': 'https://user.example/new.pac',
              'hasAutoDetect': true,
              'autoDetect': 1,
            }),
            '',
          );
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);

    expect(
      scripts.where(
        (script) =>
            script.contains('EndpointRestoreInProgress -Type DWord -Value 1'),
      ),
      hasLength(1),
    );
    expect(
      scripts.where(
        (script) =>
            script.contains('-Name RestoreInProgress -Type DWord -Value 1'),
      ),
      isEmpty,
    );
    expect(await backup.exists(), isFalse);
    expect(service.recoveryPending, isFalse);
  });

  test('foreign fields during activation still release the owned endpoint',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_activation_foreign_fields_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final runtime = Directory(
      '${temp.path}${Platform.pathSeparator}SSRVPN'
      '${Platform.pathSeparator}runtime',
    );
    await runtime.create(recursive: true);
    final backup = File(
      '${runtime.path}${Platform.pathSeparator}system_proxy_backup.json',
    );
    await backup.writeAsString(
      jsonEncode({
        'hasProxyEnable': true,
        'proxyEnable': 0,
        'hasProxyServer': false,
        'proxyServer': '',
        'hasProxyOverride': false,
        'proxyOverride': '',
        'hasAutoConfigUrl': false,
        'autoConfigUrl': '',
        'hasAutoDetect': false,
        'autoDetect': 0,
        '_ownedProxyServer': '127.0.0.1:7890',
        '_activationInProgress': true,
      }),
    );
    final scripts = <String>[];
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        scripts.add(script);
        if (script.contains("[Console]::Out.Write('ACTIVATION')")) {
          return ProcessResult(1, 0, 'ACTIVATION', '');
        }
        if (script.contains('ConvertTo-Json -Compress')) {
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'hasProxyEnable': true,
              'proxyEnable': 1,
              'hasProxyServer': true,
              'proxyServer': '127.0.0.1:7890',
              'hasProxyOverride': true,
              'proxyOverride': 'user-updated-bypass',
              'hasAutoConfigUrl': true,
              'autoConfigUrl': 'https://user.example/new.pac',
              'hasAutoDetect': true,
              'autoDetect': 1,
            }),
            '',
          );
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);

    expect(
      scripts.where(
        (script) =>
            script.contains('EndpointRestoreInProgress -Type DWord -Value 1'),
      ),
      hasLength(1),
    );
    expect(
      scripts.where(
        (script) =>
            script.contains('-Name RestoreInProgress -Type DWord -Value 1'),
      ),
      isEmpty,
    );
    expect(await backup.exists(), isFalse);
    expect(service.recoveryPending, isFalse);
  });

  test('native pending flags never overwrite a foreign proxy fingerprint',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_foreign_proxy_during_recovery_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final runtime = Directory(
      '${temp.path}${Platform.pathSeparator}SSRVPN'
      '${Platform.pathSeparator}runtime',
    );
    await runtime.create(recursive: true);
    final backup = File(
      '${runtime.path}${Platform.pathSeparator}system_proxy_backup.json',
    );
    await backup.writeAsString(
      jsonEncode({
        'proxyEnable': 0,
        'hasProxyServer': false,
        'proxyServer': '',
        'hasProxyOverride': false,
        'proxyOverride': '',
        'hasAutoConfigUrl': false,
        'autoConfigUrl': '',
        'hasAutoDetect': false,
        'autoDetect': 0,
        '_ownedProxyServer': '127.0.0.1:7890',
        '_activationInProgress': true,
      }),
    );
    final scripts = <String>[];
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        scripts.add(script);
        if (script.contains("[Console]::Out.Write('ACTIVATION')")) {
          return ProcessResult(1, 0, 'ACTIVATION', '');
        }
        if (script.contains("[Console]::Out.Write('pending')")) {
          return ProcessResult(1, 0, 'pending', '');
        }
        if (script.contains('ConvertTo-Json -Compress')) {
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'proxyEnable': 1,
              'hasProxyServer': true,
              'proxyServer': '127.0.0.1:9911',
              'hasProxyOverride': true,
              'proxyOverride': 'foreign override',
              'hasAutoConfigUrl': true,
              'autoConfigUrl': 'https://foreign.example/proxy.pac',
              'hasAutoDetect': true,
              'autoDetect': 1,
            }),
            '',
          );
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);

    expect(
      scripts.any(
        (script) => script.contains(
          '-Name RestoreInProgress -Type DWord -Value 1',
        ),
      ),
      isFalse,
    );
    expect(
      scripts.any(
        (script) => script.contains(
          '-Name EndpointRestoreInProgress -Type DWord -Value 1',
        ),
      ),
      isFalse,
    );
    expect(await backup.exists(), isFalse);
    expect(service.recoveryPending, isFalse);
  });

  test('startup restore preserves retry state when RunOnce cleanup fails',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_startup_safe_cleanup_failure_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final runtime = Directory(
      '${temp.path}${Platform.pathSeparator}SSRVPN'
      '${Platform.pathSeparator}runtime',
    );
    await runtime.create(recursive: true);
    final backup = File(
      '${runtime.path}${Platform.pathSeparator}system_proxy_backup.json',
    );
    await backup.writeAsString(
      jsonEncode({
        'proxyEnable': 0,
        'hasProxyServer': false,
        'proxyServer': '',
        'hasProxyOverride': false,
        'proxyOverride': '',
        'hasAutoConfigUrl': false,
        'autoConfigUrl': '',
        'hasAutoDetect': false,
        'autoDetect': 0,
        '_ownedProxyServer': '127.0.0.1:7890',
        '_activationInProgress': false,
      }),
    );

    var reads = 0;
    var cleanupAttempts = 0;
    var allowCleanup = false;
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        if (script.contains("[Console]::Out.Write('ACTIVATION')")) {
          return ProcessResult(1, 0, 'FULL_RESTORE', '');
        }
        if (script.contains('ConvertTo-Json -Compress')) {
          reads += 1;
          final connected = reads == 1;
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'proxyEnable': connected ? 1 : 0,
              'hasProxyServer': connected,
              'proxyServer': connected ? '127.0.0.1:7890' : '',
              'hasProxyOverride': connected,
              'proxyOverride': connected
                  ? '<local>;localhost;127.*;10.*;172.16.*;172.17.*;'
                      '172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;'
                      '172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;'
                      '172.28.*;172.29.*;172.30.*;172.31.*;192.168.*'
                  : '',
              'hasAutoConfigUrl': false,
              'autoConfigUrl': '',
              'hasAutoDetect': connected,
              'autoDetect': 0,
            }),
            '',
          );
        }
        if (script.contains('Remove-ItemProperty -LiteralPath')) {
          cleanupAttempts += 1;
          if (allowCleanup) return ProcessResult(1, 0, '', '');
          return ProcessResult(1, 1, '', 'all cleanup paths denied');
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);

    expect(reads, 2);
    expect(cleanupAttempts, 2);
    expect(service.isProxyEnabled, isFalse);
    expect(service.recoveryPending, isTrue);
    expect(service.endpointSafeWithPendingRecovery, isTrue);
    expect(service.lastError, contains('恢复日志清理失败'));
    expect(service.lastError, contains('代理端点已安全释放'));
    expect(await backup.exists(), isTrue);

    allowCleanup = true;
    expect(await service.retryPendingRecovery(), isTrue);
    expect(reads, 3);
    expect(service.recoveryPending, isFalse);
    expect(service.endpointSafeWithPendingRecovery, isFalse);
    expect(await backup.exists(), isFalse);
  });

  test('a failed retry preserves the recovery backup', () async {
    final temp = await Directory.systemTemp.createTemp('ssrvpn_proxy_keep_');
    addTearDown(() => temp.delete(recursive: true));
    final runtime = Directory(
      '${temp.path}${Platform.pathSeparator}SSRVPN'
      '${Platform.pathSeparator}runtime',
    );
    await runtime.create(recursive: true);
    final backup = File(
      '${runtime.path}${Platform.pathSeparator}system_proxy_backup.json',
    );
    await backup.writeAsString('{"invalid":true}');
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (_) async => ProcessResult(1, 124, '', 'timeout'),
    );

    await service.initialize(temp.path);
    expect(await service.retryPendingRecovery(), isFalse);

    expect(service.recoveryPending, isTrue);
    expect(await backup.exists(), isTrue);
    expect(await service.clearSystemProxy(), isFalse);
  });

  test('a failed normal disconnect becomes retryable recovery state', () async {
    final temp = await Directory.systemTemp.createTemp('ssrvpn_proxy_clear_');
    addTearDown(() => temp.delete(recursive: true));

    final ownedSnapshot = jsonEncode({
      'proxyEnable': 1,
      'hasProxyServer': true,
      'proxyServer': '127.0.0.1:7890',
      'hasProxyOverride': true,
      'proxyOverride':
          '<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;'
              '172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;'
              '172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;'
              '172.31.*;192.168.*',
      'hasAutoConfigUrl': false,
      'autoConfigUrl': '',
      'hasAutoDetect': true,
      'autoDetect': 0,
    });
    var reads = 0;
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        if (script.contains('ConvertTo-Json -Compress')) {
          reads += 1;
          return ProcessResult(
            1,
            0,
            reads == 1
                ? jsonEncode({
                    'proxyEnable': 0,
                    'hasProxyServer': false,
                    'proxyServer': '',
                    'hasProxyOverride': false,
                    'proxyOverride': '',
                    'hasAutoConfigUrl': false,
                    'autoConfigUrl': '',
                    'hasAutoDetect': false,
                    'autoDetect': 0,
                  })
                : ownedSnapshot,
            '',
          );
        }
        if (script.contains(
          r'Set-ItemProperty -Path $regPath -Name ProxyEnable -Type DWord -Value 0',
        )) {
          return ProcessResult(1, 1, '', 'registry temporarily unavailable');
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isTrue);

    expect(await service.clearSystemProxy(), isFalse);
    expect(service.recoveryPending, isTrue);
    expect(service.lastError, contains('恢复 Windows 系统代理失败'));
    final backup = File(
      '${temp.path}${Platform.pathSeparator}SSRVPN'
      '${Platform.pathSeparator}runtime${Platform.pathSeparator}'
      'system_proxy_backup.json',
    );
    expect(await backup.exists(), isTrue);
  });

  test('endpoint-safe state remains explicit when all journal cleanup fails',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_safe_cleanup_failure_',
    );
    addTearDown(() => temp.delete(recursive: true));
    var reads = 0;
    var restoreCommitFailed = false;
    var allowRestoreCommit = false;
    var restoreCompleted = false;
    var cleanupFallbackFailed = false;
    var allowCleanupFallback = false;
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        if (script.contains("[Console]::Out.Write('FULL_RESTORE')")) {
          return ProcessResult(
            1,
            0,
            restoreCompleted ? 'TERMINAL' : 'FULL_RESTORE',
            '',
          );
        }
        if (script.contains('ConvertTo-Json -Compress')) {
          reads += 1;
          final connected = reads == 2 || reads == 3;
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'proxyEnable': connected ? 1 : 0,
              'hasProxyServer': connected,
              'proxyServer': connected ? '127.0.0.1:7890' : '',
              'hasProxyOverride': connected,
              'proxyOverride': connected
                  ? '<local>;localhost;127.*;10.*;172.16.*;172.17.*;'
                      '172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;'
                      '172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;'
                      '172.28.*;172.29.*;172.30.*;172.31.*;192.168.*'
                  : '',
              'hasAutoConfigUrl': false,
              'autoConfigUrl': '',
              'hasAutoDetect': connected,
              'autoDetect': 0,
            }),
            '',
          );
        }
        if (script.contains(r'$regPath') &&
            script.contains('-Name Valid -Type DWord -Value 0')) {
          restoreCommitFailed = true;
          expect(script, contains(r'$validTerminal -or $flagsTerminal'));
          if (allowRestoreCommit) {
            restoreCompleted = true;
            return ProcessResult(1, 0, '', '');
          }
          return ProcessResult(1, 1, '', 'native cleanup denied');
        }
        if (script.contains('Native proxy recovery cleanup failed')) {
          expect(script, contains('RestoreInProgress'));
          expect(script, contains('EndpointRestoreInProgress'));
          expect(script, contains('ActivationInProgress'));
          expect(script, contains(r'Remove-Item -LiteralPath $backupPath'));
          expect(
            script.indexOf('-Name Valid -Type DWord -Value 0'),
            lessThan(script.indexOf('RestoreInProgress')),
          );
          expect(
            script.indexOf('ActivationInProgress'),
            lessThan(script.indexOf(r'Remove-Item -LiteralPath $backupPath')),
          );
          expect(
            script,
            contains(r'if ($flagsTerminal) { $terminalized = $true }'),
          );
          expect(
            script,
            contains(r'if (-not ($terminalized -or $removed))'),
          );
          if (allowCleanupFallback) return ProcessResult(1, 0, '', '');
          cleanupFallbackFailed = true;
          return ProcessResult(1, 1, '', 'all native cleanup paths denied');
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isTrue);

    expect(await service.clearSystemProxy(), isFalse);
    expect(service.isProxyEnabled, isFalse);
    expect(service.recoveryPending, isTrue);
    expect(service.endpointSafeWithPendingRecovery, isTrue);
    expect(service.lastError, contains('代理端点已安全释放'));
    expect(service.lastError, contains('原设置尚未完整恢复'));
    expect(restoreCommitFailed, isTrue);
    expect(cleanupFallbackFailed, isFalse);
    final backup = File(
      '${temp.path}${Platform.pathSeparator}SSRVPN'
      '${Platform.pathSeparator}runtime${Platform.pathSeparator}'
      'system_proxy_backup.json',
    );
    expect(await backup.exists(), isTrue);
    final json =
        jsonDecode(await backup.readAsString()) as Map<String, dynamic>;
    expect(json['_activationInProgress'], isFalse);

    allowRestoreCommit = true;
    expect(await service.clearSystemProxy(), isFalse);
    expect(service.recoveryPending, isTrue);
    expect(service.endpointSafeWithPendingRecovery, isTrue);
    expect(service.lastError, contains('恢复日志仍待清理'));
    expect(cleanupFallbackFailed, isTrue);

    allowCleanupFallback = true;
    expect(await service.clearSystemProxy(), isTrue);
    expect(service.recoveryPending, isFalse);
    expect(service.endpointSafeWithPendingRecovery, isFalse);
    expect(await backup.exists(), isFalse);
  });

  test(
      'restored original state is endpoint-safe when it shares the owned endpoint',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_same_endpoint_cleanup_failure_',
    );
    addTearDown(() => temp.delete(recursive: true));
    const original = {
      'hasProxyEnable': true,
      'proxyEnable': 1,
      'hasProxyServer': true,
      'proxyServer': '127.0.0.1:7890',
      'hasProxyOverride': true,
      'proxyOverride': 'corp-bypass',
      'hasAutoConfigUrl': true,
      'autoConfigUrl': 'https://corp.example/proxy.pac',
      'hasAutoDetect': true,
      'autoDetect': 1,
    };
    const owned = {
      'hasProxyEnable': true,
      'proxyEnable': 1,
      'hasProxyServer': true,
      'proxyServer': '127.0.0.1:7890',
      'hasProxyOverride': true,
      'proxyOverride': '<local>;localhost;127.*;10.*;172.16.*;172.17.*;'
          '172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;'
          '172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;'
          '172.30.*;172.31.*;192.168.*',
      'hasAutoConfigUrl': false,
      'autoConfigUrl': '',
      'hasAutoDetect': true,
      'autoDetect': 0,
    };
    var current = original;
    var cleanupAttempts = 0;
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        if (script.contains('ConvertTo-Json -Compress')) {
          return ProcessResult(1, 0, jsonEncode(current), '');
        }
        if (script.contains(
          '-Name RestoreInProgress -Type DWord -Value 1',
        )) {
          current = original;
          return ProcessResult(1, 0, '', '');
        }
        if (script.contains(r'$regPath') &&
            script.contains(
              r'Set-ItemProperty -Path $regPath -Name ProxyOverride',
            ) &&
            script.contains(
              r'Set-ItemProperty -Path $regPath -Name ProxyEnable '
              r'-Type DWord -Value 1',
            )) {
          current = owned;
          return ProcessResult(1, 0, '', '');
        }
        if (script.contains('Native proxy recovery cleanup failed')) {
          cleanupAttempts += 1;
          return ProcessResult(1, 1, '', 'native cleanup denied');
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isTrue);

    expect(await service.clearSystemProxy(), isFalse);
    expect(current, original);
    expect(cleanupAttempts, 2);
    expect(service.isProxyEnabled, isFalse);
    expect(service.recoveryPending, isTrue);
    expect(service.endpointSafeWithPendingRecovery, isTrue);
    expect(service.lastError, contains('恢复日志仍待清理'));
  });

  test('guardian check precedes backup, RunOnce, and proxy enable', () async {
    final temp = await Directory.systemTemp.createTemp('ssrvpn_runonce_');
    addTearDown(() => temp.delete(recursive: true));
    final scripts = <String>[];
    var proxyReads = 0;
    const executable = r'C:\Program Files\SSRVPN 测试\ssrvpn_windows_app.exe';
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      recoveryExecutable: executable,
      scriptRunner: (script) async {
        scripts.add(script);
        if (script.contains('ConvertTo-Json -Compress')) {
          proxyReads += 1;
          final connected = proxyReads > 1;
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'proxyEnable': connected ? 1 : 0,
              'hasProxyServer': connected,
              'proxyServer': connected ? '127.0.0.1:7890' : '',
              'hasProxyOverride': connected,
              'proxyOverride': connected
                  ? '<local>;localhost;127.*;10.*;172.16.*;172.17.*;'
                      '172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;'
                      '172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;'
                      '172.28.*;172.29.*;172.30.*;172.31.*;192.168.*'
                  : '',
              'hasAutoConfigUrl': false,
              'autoConfigUrl': '',
              'hasAutoDetect': connected,
              'autoDetect': 0,
            }),
            '',
          );
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isTrue);

    final guardian = scripts.indexWhere(
      (script) => script.contains('SSRVPN_Windows_LauncherGuardian'),
    );
    final nativeBackup = scripts.indexWhere(
      (script) => script.contains('-Name Valid -Type DWord -Value 1'),
    );
    final runOnce = scripts.indexWhere(
      (script) => script.contains(
        "-Name 'SSRVPNProxyRecovery' -Type String",
      ),
    );
    final proxyEnable = scripts.indexWhere(
      (script) => script.contains(
        r'Set-ItemProperty -Path $regPath -Name ProxyEnable '
        r'-Type DWord -Value 1',
      ),
    );
    expect(guardian, greaterThanOrEqualTo(0));
    expect(scripts[guardian], contains(r'$guardian.WaitOne(0)'));
    expect(scripts[guardian], contains('AbandonedMutexException'));
    expect(scripts[guardian], contains(r'$guardian.ReleaseMutex()'));
    expect(nativeBackup, greaterThan(guardian));
    expect(runOnce, greaterThan(nativeBackup));
    expect(proxyEnable, greaterThan(runOnce));
    expect(
      scripts[runOnce],
      contains(base64Encode(utf8.encode(executable))),
    );
    expect(
      scripts[runOnce],
      contains(
        r'''-Value ('"' + $executable + '" --recover-proxy-only')''',
      ),
    );
  });

  test('missing launcher guardian refuses proxy without recovery writes',
      () async {
    final temp = await Directory.systemTemp.createTemp('ssrvpn_guardian_fail_');
    addTearDown(() => temp.delete(recursive: true));
    final scripts = <String>[];
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        scripts.add(script);
        if (script.contains('SSRVPN_Windows_LauncherGuardian')) {
          return ProcessResult(1, 1, '', 'mutex missing');
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isFalse);

    expect(scripts, hasLength(1));
    expect(scripts.single, contains('SSRVPN_Windows_LauncherGuardian'));
    expect(scripts.single, isNot(contains('RuntimeProxyBackup')));
    expect(scripts.single, isNot(contains('SSRVPNProxyRecovery')));
    expect(scripts.single, isNot(contains('ProxyEnable')));
    expect(
      service.lastError,
      '独立系统代理保护未就绪，请通过 ssrvpn_windows.exe 启动或重试',
    );
    final backup = File(
      '${temp.path}${Platform.pathSeparator}SSRVPN'
      '${Platform.pathSeparator}runtime${Platform.pathSeparator}'
      'system_proxy_backup.json',
    );
    expect(await backup.exists(), isFalse);
  });

  test('guardian readiness check returns when its caller cancels', () async {
    final guardianStarted = Completer<void>();
    final neverReturns = Completer<ProcessResult>();
    final cancellation = Completer<void>();
    final service = SystemProxyService.forTesting(
      isWindows: true,
      scriptRunner: (script) {
        expect(script, contains(r'Mutex]::OpenExisting'));
        guardianStarted.complete();
        return neverReturns.future;
      },
    );

    final checking = service.isLauncherGuardianReady(
      cancellation: cancellation.future,
    );
    await guardianStarted.future.timeout(const Duration(seconds: 1));

    cancellation.complete();

    expect(
      await checking.timeout(const Duration(seconds: 1)),
      isFalse,
    );
  });

  test('proxy acquisition cancellation aborts write and rolls back', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_proxy_cancel_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final proxyWriteStarted = Completer<void>();
    final stalledProxyWrite = Completer<ProcessResult>();
    final cancellation = Completer<void>();
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        if (script.contains('ConvertTo-Json -Compress')) {
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'hasProxyEnable': true,
              'proxyEnable': 0,
              'hasProxyServer': false,
              'proxyServer': '',
              'hasProxyOverride': false,
              'proxyOverride': '',
              'hasAutoConfigUrl': false,
              'autoConfigUrl': '',
              'hasAutoDetect': false,
              'autoDetect': 0,
            }),
            '',
          );
        }
        final isProxyActivation = script.contains(
                r'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings') &&
            script.contains(
              r'Set-ItemProperty -Path $regPath -Name ProxyEnable -Type DWord -Value 1',
            ) &&
            !script.contains('OriginalProxyEnable');
        if (isProxyActivation) {
          if (!proxyWriteStarted.isCompleted) proxyWriteStarted.complete();
          return stalledProxyWrite.future;
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);
    final setting = service.setSystemProxy(
      '127.0.0.1',
      7890,
      cancellation: cancellation.future,
    );
    await proxyWriteStarted.future.timeout(const Duration(seconds: 1));

    cancellation.complete();

    expect(await setting.timeout(const Duration(seconds: 1)), isFalse);
    expect(service.isProxyEnabled, isFalse);
    expect(service.recoveryPending, isFalse);
    expect(service.lastError, contains('已取消'));
    final backup = File(
      '${temp.path}${Platform.pathSeparator}SSRVPN'
      '${Platform.pathSeparator}runtime${Platform.pathSeparator}'
      'system_proxy_backup.json',
    );
    expect(await backup.exists(), isFalse);
  });

  test('cancelling journal preparation never restores an untouched endpoint',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_proxy_prepare_cancel_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final scripts = <String>[];
    final runOnceStarted = Completer<void>();
    final stalledRunOnce = Completer<ProcessResult>();
    final cancellation = Completer<void>();
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        scripts.add(script);
        if (script.contains('ConvertTo-Json -Compress')) {
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'hasProxyEnable': true,
              'proxyEnable': 1,
              'hasProxyServer': true,
              'proxyServer': '127.0.0.1:7890',
              'hasProxyOverride': true,
              'proxyOverride': 'user-owned-bypass',
              'hasAutoConfigUrl': false,
              'autoConfigUrl': '',
              'hasAutoDetect': true,
              'autoDetect': 1,
            }),
            '',
          );
        }
        final isRunOnceRegistration = script.contains('SSRVPNProxyRecovery') &&
            script.contains('Set-ItemProperty') &&
            !script.contains('Remove-ItemProperty');
        if (isRunOnceRegistration) {
          if (!runOnceStarted.isCompleted) runOnceStarted.complete();
          return stalledRunOnce.future;
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);
    final setting = service.setSystemProxy(
      '127.0.0.1',
      7890,
      cancellation: cancellation.future,
    );
    await runOnceStarted.future.timeout(const Duration(seconds: 1));

    cancellation.complete();

    expect(await setting.timeout(const Duration(seconds: 1)), isFalse);
    expect(service.isProxyEnabled, isFalse);
    expect(service.recoveryPending, isFalse);
    expect(service.lastError, contains('已取消'));
    expect(
      scripts.where(
        (script) =>
            script.contains('-Name RestoreInProgress -Type DWord -Value 1'),
      ),
      isEmpty,
    );
    final backup = File(
      '${temp.path}${Platform.pathSeparator}SSRVPN'
      '${Platform.pathSeparator}runtime${Platform.pathSeparator}'
      'system_proxy_backup.json',
    );
    expect(await backup.exists(), isFalse);
  });

  for (final interruptedStage in ['native journal', 'RunOnce']) {
    test(
        'unconfirmed $interruptedStage preparation waits before discarding state',
        () async {
      final temp = await Directory.systemTemp.createTemp(
        'ssrvpn_proxy_prepare_unconfirmed_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final scripts = <String>[];
      final pendingProcessExit = Completer<int>();
      final service = SystemProxyService.forTesting(
        isWindows: true,
        localAppData: temp.path,
        scriptRunner: (script) async {
          scripts.add(script);
          if (script.contains("[Console]::Out.Write('TERMINAL')")) {
            return ProcessResult(1, 0, 'TERMINAL', '');
          }
          if (script.contains('ConvertTo-Json -Compress')) {
            return ProcessResult(
              1,
              0,
              jsonEncode({
                'hasProxyEnable': true,
                'proxyEnable': 1,
                'hasProxyServer': true,
                'proxyServer': '127.0.0.1:7890',
                'hasProxyOverride': true,
                'proxyOverride': 'user-owned-bypass',
                'hasAutoConfigUrl': false,
                'autoConfigUrl': '',
                'hasAutoDetect': true,
                'autoDetect': 1,
              }),
              '',
            );
          }
          final isNativeJournal = script.contains('OriginalProxyEnable') &&
              script.contains('OwnedProxyServer');
          final isRunOnce = script.contains('SSRVPNProxyRecovery') &&
              script.contains('Set-ItemProperty') &&
              !script.contains('Remove-ItemProperty');
          if ((interruptedStage == 'native journal' && isNativeJournal) ||
              (interruptedStage == 'RunOnce' && isRunOnce)) {
            throw ProcessTerminationNotConfirmedException(
              pendingProcessExit.future,
            );
          }
          return ProcessResult(1, 0, '', '');
        },
      );

      await service.initialize(temp.path);
      expect(await service.setSystemProxy('127.0.0.1', 7890), isFalse);
      expect(service.recoveryPending, isTrue);
      final scriptCountBeforeClear = scripts.length;

      var clearReturned = false;
      final clearing = service.clearSystemProxy()
        ..then<void>((_) => clearReturned = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(clearReturned, isFalse);
      expect(scripts, hasLength(scriptCountBeforeClear));

      pendingProcessExit.complete(125);

      expect(await clearing.timeout(const Duration(seconds: 1)), isTrue);
      expect(service.recoveryPending, isFalse);
      expect(
        scripts.where(
          (script) =>
              script.contains('-Name RestoreInProgress -Type DWord -Value 1'),
        ),
        isEmpty,
      );
      final backup = File(
        '${temp.path}${Platform.pathSeparator}SSRVPN'
        '${Platform.pathSeparator}runtime${Platform.pathSeparator}'
        'system_proxy_backup.json',
      );
      expect(await backup.exists(), isFalse);
    });
  }

  test('late prep exit is discarded before retry and cannot taint next lease',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_proxy_prepare_retry_',
    );
    addTearDown(() => temp.delete(recursive: true));
    const ownedOverride =
        '<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;'
        '172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;'
        '172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*';
    final scripts = <String>[];
    final pendingProcessExit = Completer<int>();
    var firstRunOnce = true;
    var ssrvpnOwnsLiveProxy = false;
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      pendingCommandExitTimeout: const Duration(milliseconds: 20),
      scriptRunner: (script) async {
        scripts.add(script);
        if (script.contains('ConvertTo-Json -Compress')) {
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'hasProxyEnable': true,
              'proxyEnable': 1,
              'hasProxyServer': true,
              'proxyServer': '127.0.0.1:7890',
              'hasProxyOverride': true,
              'proxyOverride':
                  ssrvpnOwnsLiveProxy ? ownedOverride : 'user-owned-bypass',
              'hasAutoConfigUrl': false,
              'autoConfigUrl': '',
              'hasAutoDetect': true,
              'autoDetect': ssrvpnOwnsLiveProxy ? 0 : 1,
            }),
            '',
          );
        }
        final isRunOnce = script.contains('SSRVPNProxyRecovery') &&
            script.contains('Set-ItemProperty') &&
            !script.contains('Remove-ItemProperty');
        if (firstRunOnce && isRunOnce) {
          firstRunOnce = false;
          throw ProcessTerminationNotConfirmedException(
            pendingProcessExit.future,
          );
        }
        final isRestore =
            script.contains('-Name RestoreInProgress -Type DWord -Value 1');
        if (isRestore) ssrvpnOwnsLiveProxy = false;
        final isActivation = script.contains(
                r'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings') &&
            script.contains(
              r'Set-ItemProperty -Path $regPath -Name ProxyEnable -Type DWord -Value 1',
            ) &&
            !isRestore &&
            !script.contains('OriginalProxyEnable');
        if (isActivation) ssrvpnOwnsLiveProxy = true;
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isFalse);
    expect(service.recoveryPending, isTrue);
    expect(await service.clearSystemProxy(), isFalse);

    pendingProcessExit.complete(125);
    await Future<void>.delayed(Duration.zero);

    expect(await service.retryPendingRecovery(), isTrue);
    expect(service.recoveryPending, isFalse);
    expect(
      scripts.where(
        (script) =>
            script.contains('-Name RestoreInProgress -Type DWord -Value 1'),
      ),
      isEmpty,
    );

    expect(await service.setSystemProxy('127.0.0.1', 7890), isTrue);
    expect(ssrvpnOwnsLiveProxy, isTrue);
    expect(await service.clearSystemProxy(), isTrue);
    expect(ssrvpnOwnsLiveProxy, isFalse);
    expect(service.recoveryPending, isFalse);
    expect(
      scripts.where(
        (script) =>
            script.contains('-Name RestoreInProgress -Type DWord -Value 1'),
      ),
      hasLength(1),
    );
  });

  test('queued clear rechecks the pending-process gate after taking the lock',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_proxy_lock_gate_',
    );
    addTearDown(() => temp.delete(recursive: true));
    const ownedOverride =
        '<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;'
        '172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;'
        '172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*';
    final scripts = <String>[];
    final activationStarted = Completer<void>();
    final activationResult = Completer<ProcessResult>();
    final pendingProcessExit = Completer<int>();
    var proxyReads = 0;
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        scripts.add(script);
        if (script.contains('ConvertTo-Json -Compress')) {
          proxyReads += 1;
          final connected = proxyReads > 1;
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'hasProxyEnable': true,
              'proxyEnable': connected ? 1 : 0,
              'hasProxyServer': connected,
              'proxyServer': connected ? '127.0.0.1:7890' : '',
              'hasProxyOverride': connected,
              'proxyOverride': connected ? ownedOverride : '',
              'hasAutoConfigUrl': false,
              'autoConfigUrl': '',
              'hasAutoDetect': true,
              'autoDetect': connected ? 0 : 1,
            }),
            '',
          );
        }
        final isActivation = script.contains(
                r'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings') &&
            script.contains(
              r'Set-ItemProperty -Path $regPath -Name ProxyEnable -Type DWord -Value 1',
            ) &&
            !script.contains('OriginalProxyEnable');
        if (isActivation) {
          activationStarted.complete();
          return activationResult.future;
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);
    final setting = service.setSystemProxy('127.0.0.1', 7890);
    await activationStarted.future.timeout(const Duration(seconds: 1));
    final clearing = service.clearSystemProxy();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final scriptsBeforeFailure = scripts.length;

    activationResult.completeError(
      ProcessTerminationNotConfirmedException(pendingProcessExit.future),
    );
    expect(await setting.timeout(const Duration(seconds: 1)), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(scripts, hasLength(scriptsBeforeFailure));

    pendingProcessExit.complete(125);

    expect(await clearing.timeout(const Duration(seconds: 1)), isTrue);
    expect(service.recoveryPending, isFalse);
  });

  for (final interruptedStage in ['restore', 'journal cleanup']) {
    test('clear waits when $interruptedStage exit is unconfirmed', () async {
      final temp = await Directory.systemTemp.createTemp(
        'ssrvpn_proxy_clear_unconfirmed_',
      );
      addTearDown(() => temp.delete(recursive: true));
      const ownedOverride =
          '<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;'
          '172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;'
          '172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*';
      final scripts = <String>[];
      final pendingProcessExit = Completer<int>();
      var interruptOnce = true;
      var ssrvpnOwnsLiveProxy = false;
      final service = SystemProxyService.forTesting(
        isWindows: true,
        localAppData: temp.path,
        scriptRunner: (script) async {
          scripts.add(script);
          if (script.contains("[Console]::Out.Write('TERMINAL')")) {
            return ProcessResult(1, 0, 'TERMINAL', '');
          }
          if (script.contains('ConvertTo-Json -Compress')) {
            return ProcessResult(
              1,
              0,
              jsonEncode({
                'hasProxyEnable': true,
                'proxyEnable': ssrvpnOwnsLiveProxy ? 1 : 0,
                'hasProxyServer': ssrvpnOwnsLiveProxy,
                'proxyServer': ssrvpnOwnsLiveProxy ? '127.0.0.1:7890' : '',
                'hasProxyOverride': ssrvpnOwnsLiveProxy,
                'proxyOverride': ssrvpnOwnsLiveProxy ? ownedOverride : '',
                'hasAutoConfigUrl': false,
                'autoConfigUrl': '',
                'hasAutoDetect': true,
                'autoDetect': ssrvpnOwnsLiveProxy ? 0 : 1,
              }),
              '',
            );
          }
          final isRestore =
              script.contains('-Name RestoreInProgress -Type DWord -Value 1');
          final isJournalCleanup =
              script.contains('Native proxy recovery cleanup failed');
          if (interruptOnce &&
              ((interruptedStage == 'restore' && isRestore) ||
                  (interruptedStage == 'journal cleanup' &&
                      isJournalCleanup))) {
            interruptOnce = false;
            throw ProcessTerminationNotConfirmedException(
              pendingProcessExit.future,
            );
          }
          if (isRestore) ssrvpnOwnsLiveProxy = false;
          final isActivation = script.contains(
                  r'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings') &&
              script.contains(
                r'Set-ItemProperty -Path $regPath -Name ProxyEnable -Type DWord -Value 1',
              ) &&
              !script.contains('OriginalProxyEnable') &&
              !isRestore;
          if (isActivation) ssrvpnOwnsLiveProxy = true;
          return ProcessResult(1, 0, '', '');
        },
      );

      await service.initialize(temp.path);
      expect(await service.setSystemProxy('127.0.0.1', 7890), isTrue);
      expect(await service.clearSystemProxy(), isFalse);
      expect(service.recoveryPending, isTrue);
      final scriptsBeforeRetry = scripts.length;

      var retryReturned = false;
      final retrying = service.clearSystemProxy()
        ..then<void>((_) => retryReturned = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(retryReturned, isFalse);
      expect(scripts, hasLength(scriptsBeforeRetry));

      pendingProcessExit.complete(125);

      expect(await retrying.timeout(const Duration(seconds: 1)), isTrue);
      expect(ssrvpnOwnsLiveProxy, isFalse);
      expect(service.recoveryPending, isFalse);
    });
  }

  test('rollback waits for an unconfirmed cancelled proxy command to exit',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_proxy_exit_confirmation_',
    );
    addTearDown(() => temp.delete(recursive: true));
    const ownedOverride =
        '<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;'
        '172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;'
        '172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*';
    final scripts = <String>[];
    final pendingProcessExit = Completer<int>();
    var proxyReads = 0;
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        scripts.add(script);
        if (script.contains('ConvertTo-Json -Compress')) {
          proxyReads += 1;
          final connected = proxyReads > 1;
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'hasProxyEnable': true,
              'proxyEnable': connected ? 1 : 0,
              'hasProxyServer': connected,
              'proxyServer': connected ? '127.0.0.1:7890' : '',
              'hasProxyOverride': connected,
              'proxyOverride': connected ? ownedOverride : '',
              'hasAutoConfigUrl': false,
              'autoConfigUrl': '',
              'hasAutoDetect': true,
              'autoDetect': connected ? 0 : 1,
            }),
            '',
          );
        }
        final isProxyActivation = script.contains(
                r'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings') &&
            script.contains(
              r'Set-ItemProperty -Path $regPath -Name ProxyEnable -Type DWord -Value 1',
            ) &&
            !script.contains('OriginalProxyEnable');
        if (isProxyActivation) {
          throw ProcessTerminationNotConfirmedException(
            pendingProcessExit.future,
          );
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isFalse);
    expect(service.recoveryPending, isTrue);
    expect(service.lastError, contains('确认'));
    expect(
      scripts.where(
        (script) =>
            script.contains('-Name RestoreInProgress -Type DWord -Value 1'),
      ),
      isEmpty,
    );

    var clearReturned = false;
    final clearing = service.clearSystemProxy()
      ..then<void>((_) => clearReturned = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(clearReturned, isFalse);
    expect(
      scripts.where(
        (script) =>
            script.contains('-Name RestoreInProgress -Type DWord -Value 1'),
      ),
      isEmpty,
    );

    pendingProcessExit.complete(125);

    expect(await clearing.timeout(const Duration(seconds: 1)), isTrue);
    expect(clearReturned, isTrue);
    expect(service.recoveryPending, isFalse);
    expect(
      scripts.where(
        (script) =>
            script.contains('-Name RestoreInProgress -Type DWord -Value 1'),
      ),
      hasLength(1),
    );
  });

  test('proxy acquisition rejects an out-of-band restore before commit',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_proxy_postcondition_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        if (script.contains('ConvertTo-Json -Compress')) {
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'proxyEnable': 0,
              'hasProxyServer': false,
              'proxyServer': '',
              'hasProxyOverride': false,
              'proxyOverride': '',
              'hasAutoConfigUrl': false,
              'autoConfigUrl': '',
              'hasAutoDetect': false,
              'autoDetect': 0,
            }),
            '',
          );
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isFalse);
  });

  test('RunOnce registration failure refuses to enable the proxy', () async {
    final temp = await Directory.systemTemp.createTemp('ssrvpn_runonce_fail_');
    addTearDown(() => temp.delete(recursive: true));
    final scripts = <String>[];
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      recoveryExecutable: r'C:\SSRVPN\ssrvpn_windows_app.exe',
      scriptRunner: (script) async {
        scripts.add(script);
        if (script.contains('ConvertTo-Json -Compress')) {
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'proxyEnable': 0,
              'hasProxyServer': false,
              'proxyServer': '',
              'hasProxyOverride': false,
              'proxyOverride': '',
              'hasAutoConfigUrl': false,
              'autoConfigUrl': '',
              'hasAutoDetect': false,
              'autoDetect': 0,
            }),
            '',
          );
        }
        if (script.contains("-Name 'SSRVPNProxyRecovery' -Type String")) {
          return ProcessResult(1, 1, '', 'registry denied');
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isFalse);
    expect(
      scripts.any(
        (script) => script.contains(
          r'Set-ItemProperty -Path $regPath -Name ProxyEnable '
          r'-Type DWord -Value 1',
        ),
      ),
      isFalse,
    );
    expect(
      scripts.any(
        (script) =>
            script.contains('Remove-ItemProperty') &&
            script.contains('SSRVPNProxyRecovery'),
      ),
      isTrue,
    );
    final backup = File(
      '${temp.path}${Platform.pathSeparator}SSRVPN'
      '${Platform.pathSeparator}runtime${Platform.pathSeparator}'
      'system_proxy_backup.json',
    );
    expect(await backup.exists(), isFalse);
  });

  test('a thrown partial proxy write retains recovery ownership', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_partial_proxy_throw_',
    );
    addTearDown(() => temp.delete(recursive: true));
    var endpointOwned = false;
    var restoreAttempts = 0;
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        if (script.contains('ConvertTo-Json -Compress')) {
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'proxyEnable': endpointOwned ? 1 : 0,
              'hasProxyServer': endpointOwned,
              'proxyServer': endpointOwned ? '127.0.0.1:7890' : '',
              'hasProxyOverride': endpointOwned,
              'proxyOverride': endpointOwned
                  ? '<local>;localhost;127.*;10.*;172.16.*;172.17.*;'
                      '172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;'
                      '172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;'
                      '172.28.*;172.29.*;172.30.*;172.31.*;192.168.*'
                  : '',
              'hasAutoConfigUrl': false,
              'autoConfigUrl': '',
              'hasAutoDetect': endpointOwned,
              'autoDetect': 0,
            }),
            '',
          );
        }
        if (script.contains(
          r'Set-ItemProperty -Path $backupPath '
          r'-Name RestoreInProgress -Type DWord -Value 1',
        )) {
          restoreAttempts += 1;
          return ProcessResult(1, 1, '', 'restore still unavailable');
        }
        if (script.contains(
          r'Set-ItemProperty -Path $regPath -Name ProxyEnable '
          r'-Type DWord -Value 1',
        )) {
          endpointOwned = true;
          throw StateError('synthetic exception after partial proxy write');
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isFalse);

    expect(endpointOwned, isTrue);
    expect(restoreAttempts, 1);
    expect(service.recoveryPending, isTrue);
    expect(service.endpointSafeWithPendingRecovery, isFalse);
    expect(service.lastError, contains('synthetic exception'));
    final backup = File(
      '${temp.path}${Platform.pathSeparator}SSRVPN'
      '${Platform.pathSeparator}runtime${Platform.pathSeparator}'
      'system_proxy_backup.json',
    );
    expect(await backup.exists(), isTrue);

    // A later stop must retry the snapshot restore. Returning true here would
    // let the caller kill the core while Windows still points at its endpoint.
    expect(await service.clearSystemProxy(), isFalse);
    expect(restoreAttempts, 2);
    expect(service.recoveryPending, isTrue);
    expect(service.endpointSafeWithPendingRecovery, isFalse);
  });

  test('unsafe native cleanup terminalizes JSON and preserves RunOnce',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_native_cleanup_fail_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final scripts = <String>[];
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      recoveryExecutable: r'C:\SSRVPN\ssrvpn_windows_app.exe',
      scriptRunner: (script) async {
        scripts.add(script);
        if (script.contains('ConvertTo-Json -Compress')) {
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'proxyEnable': 0,
              'hasProxyServer': false,
              'proxyServer': '',
              'hasProxyOverride': false,
              'proxyOverride': '',
              'hasAutoConfigUrl': false,
              'autoConfigUrl': '',
              'hasAutoDetect': false,
              'autoDetect': 0,
            }),
            '',
          );
        }
        if (script.contains("-Name 'SSRVPNProxyRecovery' -Type String")) {
          return ProcessResult(1, 1, '', 'RunOnce registration denied');
        }
        if (script.contains('-Name Valid -Type DWord -Value 0')) {
          return ProcessResult(1, 1, '', 'native cleanup denied');
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isFalse);

    final nativeCleanup = scripts.indexWhere(
      (script) => script.contains('-Name Valid -Type DWord -Value 0'),
    );
    expect(nativeCleanup, greaterThanOrEqualTo(0));
    expect(
      scripts.skip(nativeCleanup + 1).any(
            (script) =>
                script.contains('Remove-ItemProperty') &&
                script.contains('SSRVPNProxyRecovery'),
          ),
      isFalse,
    );
    final backup = File(
      '${temp.path}${Platform.pathSeparator}SSRVPN'
      '${Platform.pathSeparator}runtime${Platform.pathSeparator}'
      'system_proxy_backup.json',
    );
    expect(await backup.exists(), isTrue);
    final json =
        jsonDecode(await backup.readAsString()) as Map<String, dynamic>;
    expect(json['_activationInProgress'], isFalse);
    expect(service.recoveryPending, isTrue);

    final scriptCount = scripts.length;
    expect(await service.setSystemProxy('127.0.0.1', 7891), isFalse);
    expect(scripts, hasLength(scriptCount));
    expect(service.lastError, contains('仍有未恢复的旧状态'));
  });

  test('normal disconnect removes the RunOnce recovery value', () async {
    final temp = await Directory.systemTemp.createTemp('ssrvpn_runonce_clear_');
    addTearDown(() => temp.delete(recursive: true));
    final scripts = <String>[];
    var reads = 0;
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        scripts.add(script);
        if (script.contains('ConvertTo-Json -Compress')) {
          reads += 1;
          return ProcessResult(
            1,
            0,
            jsonEncode({
              'proxyEnable': reads == 1 ? 0 : 1,
              'hasProxyServer': reads != 1,
              'proxyServer': reads == 1 ? '' : '127.0.0.1:7890',
              'hasProxyOverride': reads != 1,
              'proxyOverride': reads == 1
                  ? ''
                  : '<local>;localhost;127.*;10.*;172.16.*;172.17.*;'
                      '172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;'
                      '172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;'
                      '172.28.*;172.29.*;172.30.*;172.31.*;192.168.*',
              'hasAutoConfigUrl': false,
              'autoConfigUrl': '',
              'hasAutoDetect': reads != 1,
              'autoDetect': 0,
            }),
            '',
          );
        }
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);
    expect(await service.setSystemProxy('127.0.0.1', 7890), isTrue);
    expect(await service.clearSystemProxy(), isTrue);

    expect(
      scripts.any(
        (script) =>
            script.contains('Remove-ItemProperty') &&
            script.contains('SSRVPNProxyRecovery'),
      ),
      isTrue,
    );
  });

  test('initialization without proxy state does not register RunOnce',
      () async {
    final temp = await Directory.systemTemp.createTemp('ssrvpn_runonce_idle_');
    addTearDown(() => temp.delete(recursive: true));
    final scripts = <String>[];
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: temp.path,
      scriptRunner: (script) async {
        scripts.add(script);
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(temp.path);

    expect(scripts, isEmpty);
  });

  test('missing LOCALAPPDATA refuses system proxy acquisition', () async {
    final scripts = <String>[];
    final service = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: '',
      scriptRunner: (script) async {
        scripts.add(script);
        return ProcessResult(1, 0, '', '');
      },
    );

    await service.initialize(r'C:\portable\SSRVPN');

    expect(service.recoveryPending, isTrue);
    expect(service.lastError, contains('LOCALAPPDATA'));
    expect(await service.setSystemProxy('127.0.0.1', 7890), isFalse);
    expect(scripts, isEmpty);
  });
}
