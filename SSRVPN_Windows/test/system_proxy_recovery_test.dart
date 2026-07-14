import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/system_proxy_service.dart';

void main() {
  test('every PowerShell proxy operation forces UTF-8 output first', () async {
    final temp = await Directory.systemTemp.createTemp('ssrvpn_proxy_utf8_');
    addTearDown(() => temp.delete(recursive: true));
    final scripts = <String>[];
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
              'proxyEnable': 0,
              'hasProxyServer': true,
              'proxyServer': '代理.example:8080',
              'hasProxyOverride': true,
              'proxyOverride': '本地地址',
              'hasAutoConfigUrl': true,
              'autoConfigUrl': 'https://例子.example/proxy.pac',
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
}
