import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/services/clash_service.dart';
import 'package:ssrvpn_windows/services/system_proxy_service.dart';
import 'package:ssrvpn_windows/src/services/windows_core_pid_record.dart';

ClashService _createTestService() => ClashService(
      // Lifecycle unit tests must never inspect or restore the developer's
      // live HKCU proxy journal. A real SystemProxyService here can interpret
      // an active locally installed SSRVPN session as stale crash recovery.
      systemProxyService: SystemProxyService.forTesting(
        isWindows: false,
        scriptRunner: (_) async => ProcessResult(0, 0, '', ''),
      ),
    );

void main() {
  test('periodic health timeout covers the Windows ownership probe budget', () {
    final service = _InspectableHealthTimeoutClashService();

    expect(service.exposedHealthCheckTimeout, const Duration(seconds: 25));
  });

  test('one unhealthy periodic result does not disconnect a live intent', () {
    final service = _InspectablePeriodicHealthClashService()
      ..requestConnectionIntent(true)
      ..setRunning(true);
    addTearDown(service.dispose);

    service.publishPeriodicHealth(false);

    expect(service.isRunning, isTrue);
    expect(service.connectionDesired, isTrue);
  });

  test('fresh lifecycle reports safe idle diagnostics', () async {
    final service = _createTestService();

    expect(service.isStartupDisabled, isFalse);
    expect(service.startupDisabledReason, isNull);
    expect(service.corePath, isEmpty);
    expect(service.coreExists, isFalse);
    expect(service.hasPendingSystemProxyRecovery, isFalse);
    expect(service.diagnosticConfigPath, isEmpty);
    expect(service.diagnosticConfigRequired, isTrue);
    expect(await service.diagnosticCoreAvailable(), isFalse);

    final checks = await service.platformDiagnosticChecks();
    expect(checks, hasLength(1));
    expect(checks.single.id, 'system_proxy');
    expect(checks.single.status, AppDiagnosticStatus.passed);
    expect(checks.single.errorCode, isNull);
    expect(checks.single.repairAction, isNull);
  });

  test('idle proxy recovery repair is idempotently successful', () async {
    final service = _createTestService();

    expect(await service.recoverPendingSystemProxy(), isTrue);
    final result = await service.repairDiagnosticIssue(
      AppRepairAction.retryOwnedProxyRecovery,
    );

    expect(result.success, isTrue);
    expect(result.message, contains('已恢复'));
  });

  test('proxy recovery repair refuses to run while connected', () async {
    final service = _createTestService()..setRunning(true);

    final result = await service.repairDiagnosticIssue(
      AppRepairAction.retryOwnedProxyRecovery,
    );

    expect(result.success, isFalse);
    expect(result.message, contains('请先断开连接'));
  });

  test('startup disable reason blocks start and config writes', () async {
    final service = _createTestService();
    service.disableStartup('测试启动禁用原因');

    expect(service.isStartupDisabled, isTrue);
    expect(service.startupDisabledReason, '测试启动禁用原因');
    expect(service.lastStartError, '测试启动禁用原因');
    expect(await service.start(), isFalse);
    await expectLater(
      service.writeConfig('mixed-port: 7890'),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'uninitialized lifecycle fails start without spawning a process',
    () async {
      final service = _createTestService();

      expect(await service.start(), isFalse);
      expect(service.lastStartError, contains('尚未初始化'));
    },
  );

  test(
    'automatic recovery fails safely before lifecycle initialization',
    () async {
      final service = _createTestService();

      expect(await service.startForAutomaticRecovery(), isFalse);
      expect(service.lastStartError, contains('尚未初始化'));
    },
  );

  test(
    'config validator execution failure keeps the actionable process error',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'ssrvpn_windows_config_validation_error_',
      );
      final fakeCore = File('${temp.path}${Platform.pathSeparator}mihomo.exe');
      final config = File('${temp.path}${Platform.pathSeparator}config.yaml');
      await fakeCore.writeAsString('not an executable');
      await config.writeAsString('mixed-port: 7890\n');
      final service = _createTestService();
      addTearDown(() async {
        await service.flushLogs();
        service.dispose();
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      await service.init(
        AppSettings(),
        dataDir: temp.path,
        skipCoreProbes: true,
      );
      service
        ..setCorePath(fakeCore.path)
        ..setPaths(configDir: temp.path, configPath: config.path);

      expect(await service.start(), isFalse);
      expect(service.lastStartError, isNot(contains('配置校验失败，请打开运行日志')));
      expect(
        service.lastStartError,
        anyOf(contains('安全软件'), contains('执行权限'), contains('架构不兼容')),
      );
      expect(
        AppFailure.fromMessage(service.lastStartError).code,
        anyOf(AppErrorCode.permissionRequired, AppErrorCode.coreMissing),
      );
      await service.flushLogs();
      final logs = await File(
        '${temp.path}${Platform.pathSeparator}ssrvpn.log',
      ).readAsString();
      expect(logs, contains('event=windows_config_validation_launch_failed'));
      expect(logs, isNot(contains('ProcessException:')));
      expect(logs, isNot(contains('Command:')));
    },
  );

  test('stop hook fails closed when proxy cleanup is unavailable', () async {
    final service = _createTestService();

    await expectLater(
      service.onStopRequired(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('系统代理恢复失败'),
        ),
      ),
    );

    expect(service.isRunning, isFalse);
  });

  test(
    'pending proxy recovery fails closed when its state path is unavailable',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'ssrvpn_windows_lifecycle_recovery_',
      );
      final proxy = SystemProxyService.forTesting(
        isWindows: true,
        localAppData: '',
        scriptRunner: (_) async => ProcessResult(0, 0, '', ''),
      );
      final service = ClashService(systemProxyService: proxy);
      addTearDown(() async {
        await service.flushLogs();
        service.dispose();
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      await service.init(
        AppSettings(),
        dataDir: temp.path,
        skipCoreProbes: true,
      );

      expect(service.hasPendingSystemProxyRecovery, isTrue);
      expect(await service.recoverPendingSystemProxy(), isFalse);
      expect(service.lastStartError, contains('尚未初始化'));
      expect(service.hasPendingSystemProxyRecovery, isTrue);
    },
  );

  test(
    'core PID identity record is published once and deleted by exact identity',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'ssrvpn_windows_pid_identity_',
      );
      final service = _InspectableLifecycleClashService(
        systemProxyService: SystemProxyService.forTesting(
          isWindows: false,
          scriptRunner: (_) async => ProcessResult(0, 0, '', ''),
        ),
      );
      addTearDown(() async {
        await service.flushLogs();
        service.dispose();
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      await service.init(
        AppSettings(),
        dataDir: temp.path,
        skipCoreProbes: true,
      );
      const record = WindowsCorePidRecord(
        pid: 4242,
        creationTimeUtcFileTime: '133700000000000000',
        canonicalExecutablePath: r'C:\Program Files\SSRVPN\mihomo.exe',
      );
      const differentRecord = WindowsCorePidRecord(
        pid: 4243,
        creationTimeUtcFileTime: '133700000000000001',
        canonicalExecutablePath: r'C:\Program Files\SSRVPN\mihomo.exe',
      );
      final pidFile = File('${temp.path}${Platform.pathSeparator}mihomo.pid');

      await service.persistCorePid(record);
      expect(
        WindowsCorePidRecord.tryParse(await pidFile.readAsString()),
        record,
      );
      await expectLater(
        service.persistCorePid(record),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('拒绝覆盖'),
          ),
        ),
      );
      expect(await service.removeCorePid(differentRecord), isFalse);
      expect(await pidFile.exists(), isTrue);
      expect(await service.removeCorePid(record), isTrue);
      expect(await pidFile.exists(), isFalse);
      expect(await service.removeCorePid(record), isTrue);
    },
  );

  test(
    'core PID cleanup preserves every unverified filesystem object',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'ssrvpn_windows_pid_identity_reject_',
      );
      final service = _InspectableLifecycleClashService(
        systemProxyService: SystemProxyService.forTesting(
          isWindows: false,
          scriptRunner: (_) async => ProcessResult(0, 0, '', ''),
        ),
      );
      addTearDown(() async {
        await service.flushLogs();
        service.dispose();
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      await service.init(
        AppSettings(),
        dataDir: temp.path,
        skipCoreProbes: true,
      );
      const record = WindowsCorePidRecord(
        pid: 4242,
        creationTimeUtcFileTime: '133700000000000000',
        canonicalExecutablePath: r'C:\SSRVPN\mihomo.exe',
      );
      final path = '${temp.path}${Platform.pathSeparator}mihomo.pid';

      await Directory(path).create();
      expect(await service.removeCorePid(record), isFalse);
      expect(await Directory(path).exists(), isTrue);
      await Directory(path).delete();

      for (final contents in <String>[
        '',
        'not-json',
        List.filled(maxWindowsCorePidRecordBytes + 1, 'x').join(),
      ]) {
        await File(path).writeAsString(contents);
        expect(
          await service.removeCorePid(record),
          isFalse,
          reason: 'must preserve an unverified ${contents.length}-byte record',
        );
        expect(await File(path).exists(), isTrue);
        await File(path).delete();
      }
    },
  );

  test(
    'idle initialized lifecycle stops after a terminal proxy recovery',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'ssrvpn_windows_safe_idle_stop_',
      );
      final proxy = SystemProxyService.forTesting(
        isWindows: true,
        localAppData: temp.path,
        scriptRunner: (_) async => ProcessResult(0, 0, '', ''),
      );
      final service = ClashService(systemProxyService: proxy);
      addTearDown(() async {
        await service.flushLogs();
        service.dispose();
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      await service.init(
        AppSettings(),
        dataDir: '${temp.path}${Platform.pathSeparator}data',
        skipCoreProbes: true,
      );

      service.setRunning(true);
      await service.stop();

      expect(service.isRunning, isFalse);
      expect(proxy.recoveryPending, isFalse);
      expect(
        await FileSystemEntity.type(
          '${temp.path}${Platform.pathSeparator}data'
          '${Platform.pathSeparator}mihomo.pid',
          followLinks: false,
        ),
        FileSystemEntityType.notFound,
      );
    },
  );

  test('config validation reports a real non-zero validator result', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_windows_config_validator_result_',
    );
    final config = File('${temp.path}${Platform.pathSeparator}config.yaml');
    await config.writeAsString('mixed-port: 7890\n');
    final service = _InspectableLifecycleClashService(
      systemProxyService: SystemProxyService.forTesting(
        isWindows: false,
        scriptRunner: (_) async => ProcessResult(0, 0, '', ''),
      ),
    );
    addTearDown(() async {
      await service.flushLogs();
      service.dispose();
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    await service.init(AppSettings(), dataDir: temp.path, skipCoreProbes: true);
    service
      ..setCorePath(_dartExecutable())
      ..setPaths(configDir: temp.path, configPath: config.path);

    expect(await service.runConfigValidation(), isFalse);
    expect(service.lastStartError, allOf(isNotNull, contains('配置校验失败')));
    await service.flushLogs();
    final logs = await File(service.logPath).readAsString();
    expect(logs, contains('配置校验 stderr'));
    expect(logs, contains('退出码'));
  });

  test(
    'core version probe converts launch failures into bounded diagnostics',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'ssrvpn_windows_core_version_failure_',
      );
      final service = _InspectableLifecycleClashService(
        systemProxyService: SystemProxyService.forTesting(
          isWindows: false,
          scriptRunner: (_) async => ProcessResult(0, 0, '', ''),
        ),
      );
      addTearDown(() async {
        await service.flushLogs();
        service.dispose();
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      await service.init(
        AppSettings(),
        dataDir: temp.path,
        skipCoreProbes: true,
      );
      service.setCorePath(
        '${temp.path}${Platform.pathSeparator}missing-mihomo.exe',
      );

      await service.probeCoreVersion();

      await service.flushLogs();
      final logs = await File(service.logPath).readAsString();
      expect(logs, contains('核心无法执行'));
    },
  );

  test(
    'packaged core passes config validation and version probing',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'ssrvpn_windows_packaged_core_probe_',
      );
      final config = File('${temp.path}${Platform.pathSeparator}config.yaml');
      await config.writeAsString('mixed-port: 17890\n');
      final service = _InspectableLifecycleClashService(
        systemProxyService: SystemProxyService.forTesting(
          isWindows: false,
          scriptRunner: (_) async => ProcessResult(0, 0, '', ''),
        ),
      );
      addTearDown(() async {
        await service.flushLogs();
        service.dispose();
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      await service.init(
        AppSettings(),
        dataDir: temp.path,
        skipCoreProbes: true,
      );
      service
        ..setCorePath(await _preparePackagedCore(temp))
        ..setPaths(configDir: temp.path, configPath: config.path);

      expect(await service.runConfigValidation(), isTrue);
      expect(service.lastStartError, isNull);
      await service.probeCoreVersion();

      await service.flushLogs();
      final logs = await File(service.logPath).readAsString();
      expect(logs, contains('配置校验通过'));
      expect(logs, contains('核心版本:'));
    },
    skip: !Platform.isMacOS && !Platform.isWindows,
  );

  test('non-zero version command is recorded without becoming a start error',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'ssrvpn_windows_core_version_nonzero_',
    );
    final service = _InspectableLifecycleClashService(
      systemProxyService: SystemProxyService.forTesting(
        isWindows: false,
        scriptRunner: (_) async => ProcessResult(0, 0, '', ''),
      ),
    );
    addTearDown(() async {
      await service.flushLogs();
      service.dispose();
      if (await temp.exists()) await temp.delete(recursive: true);
    });
    await service.init(AppSettings(), dataDir: temp.path, skipCoreProbes: true);
    service.setCorePath(
      Platform.isWindows
          ? '${Platform.environment['WINDIR'] ?? r'C:\Windows'}'
              r'\System32\where.exe'
          : '/usr/bin/false',
    );

    await service.probeCoreVersion();

    expect(service.lastStartError, isNull);
    await service.flushLogs();
    final logs = await File(service.logPath).readAsString();
    expect(logs, allOf(contains('核心版本检查失败'), contains('退出码')));
  });
}

class _InspectableHealthTimeoutClashService extends ClashService {
  Duration get exposedHealthCheckTimeout => healthCheckTimeout;
}

class _InspectablePeriodicHealthClashService extends ClashService {
  void publishPeriodicHealth(bool healthy) =>
      onPeriodicHealthCheckResult(healthy);
}

class _InspectableLifecycleClashService extends ClashService {
  _InspectableLifecycleClashService({required super.systemProxyService});

  Future<void> persistCorePid(WindowsCorePidRecord record) =>
      writeCorePid(record);

  Future<bool> removeCorePid(WindowsCorePidRecord record) =>
      deleteCorePid(expectedRecord: record);

  Future<bool> runConfigValidation() => validateConfig(const {});

  Future<void> probeCoreVersion() => logCoreVersion();
}

String _dartExecutable() {
  if (File(
    Platform.resolvedExecutable,
  ).uri.pathSegments.last.startsWith('dart')) {
    return Platform.resolvedExecutable;
  }
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final candidate = '$flutterRoot${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}cache${Platform.pathSeparator}dart-sdk'
        '${Platform.pathSeparator}bin${Platform.pathSeparator}dart'
        '${Platform.isWindows ? '.exe' : ''}';
    if (File(candidate).existsSync()) return candidate;
  }
  var directory = File(Platform.resolvedExecutable).parent;
  for (var depth = 0; depth < 8; depth++) {
    final candidate = '${directory.path}${Platform.pathSeparator}dart-sdk'
        '${Platform.pathSeparator}bin${Platform.pathSeparator}dart'
        '${Platform.isWindows ? '.exe' : ''}';
    if (File(candidate).existsSync()) return candidate;
    directory = directory.parent;
  }
  throw StateError('Dart executable is unavailable to the lifecycle test');
}

Future<String> _preparePackagedCore(Directory temp) async {
  final roots = <Directory>[Directory.current, Directory.current.parent];
  if (Platform.isWindows) {
    for (final root in roots) {
      for (final relative in <String>[
        'SSRVPN_Windows${Platform.pathSeparator}assets'
            '${Platform.pathSeparator}mihomo.exe',
        'assets${Platform.pathSeparator}mihomo.exe',
      ]) {
        final candidate = File(
          '${root.path}${Platform.pathSeparator}$relative',
        );
        if (await candidate.exists()) return candidate.path;
      }
    }
  } else if (Platform.isMacOS) {
    for (final root in roots) {
      final archive = File(
        '${root.path}${Platform.pathSeparator}SSRVPN_MacOS'
        '${Platform.pathSeparator}assets${Platform.pathSeparator}AtlasCore.gz',
      );
      if (!await archive.exists()) continue;
      final executable = File(
        '${temp.path}${Platform.pathSeparator}AtlasCore',
      );
      await executable.writeAsBytes(gzip.decode(await archive.readAsBytes()));
      final chmod = await Process.run('chmod', ['700', executable.path]);
      if (chmod.exitCode != 0) {
        throw StateError('Cannot make packaged macOS core executable');
      }
      return executable.path;
    }
  }
  throw StateError('Packaged core asset is unavailable to lifecycle tests');
}
