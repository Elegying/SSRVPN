import 'dart:async';
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
  group('validator process outcomes', () {
    late Directory fixture;
    late File validator;
    late File config;

    setUpAll(() async {
      fixture =
          await Directory.systemTemp.createTemp('ssrvpn_validator_fixture_');
      final source =
          File('${fixture.path}${Platform.pathSeparator}validator.dart');
      await source.writeAsString(r'''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  if (!args.contains('-t')) {
    File('${args.last}.spawned').writeAsStringSync('$pid');
    stdout.writeln('fixture runtime stdout');
    stderr.writeln('fixture runtime stderr');
    final deadline = DateTime.now().add(const Duration(minutes: 1));
    while (DateTime.now().isBefore(deadline)) {
      if (File('${args.last}.exit').existsSync()) exit(19);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return;
  }
  final config = args.contains('-t') ? File(args.last).readAsStringSync() : '';
  if (config.contains('fixtureWait')) {
    File('${args.last}.started').writeAsStringSync('ready');
    await Future<void>.delayed(const Duration(minutes: 1));
  }
  stdout.write(Platform.environment['SSRVPN_FIXTURE_STDOUT'] ?? '');
  stderr.write(Platform.environment['SSRVPN_FIXTURE_STDERR'] ?? '');
  final configuredExit = RegExp(r'# fixtureExit=(-?\d+)').firstMatch(config)?.group(1);
  exit(int.parse(Platform.environment['SSRVPN_FIXTURE_EXIT'] ?? configuredExit ?? '0'));
}
''');
      validator = File('${fixture.path}${Platform.pathSeparator}validator.exe');
      final compiled = await Process.run(_dartExecutable(),
          ['compile', 'exe', source.path, '-o', validator.path]);
      expect(compiled.exitCode, 0,
          reason: '${compiled.stdout}\n${compiled.stderr}');
      config = File('${fixture.path}${Platform.pathSeparator}config.yaml');
    });
    setUp(() async {
      await config.writeAsString('mixed-port: 7890\n');
      for (final suffix in ['started', 'spawned', 'exit']) {
        final marker = File('${config.path}.$suffix');
        if (await marker.exists()) await marker.delete();
      }
    });
    tearDownAll(() async => fixture.delete(recursive: true));

    _InspectableLifecycleClashService service() {
      final result = _InspectableLifecycleClashService(
        systemProxyService: _ControlledStopProxy(),
      )
        ..setCorePath(validator.path)
        ..setPaths(configDir: fixture.path, configPath: config.path);
      addTearDown(result.dispose);
      return result;
    }

    _StartupLifecycleClashService startup(_ControlledStopProxy proxy) {
      final core = _StartupLifecycleClashService(systemProxyService: proxy)
        ..setCorePath(validator.path)
        ..setPaths(configDir: fixture.path, configPath: config.path)
        ..requestConnectionIntent(true);
      addTearDown(() async {
        try {
          await core.stop();
        } finally {
          core.dispose();
        }
      });
      return core;
    }

    test('identity capture failure stops only the held uncommitted child',
        () async {
      final proxy = _ControlledStopProxy();
      final core = startup(proxy);
      expect(await core.start(), isFalse);
      expect(core.recentLogs, contains('Mihomo 进程已创建'));
      expect(core.recentLogs, contains('启动异常'));
      expect(core.recentLogs, contains('核心已停止'));
      expect(core.isRunning, isFalse);
      expect(proxy.setCalls, 0);
      expect(core.observationSchedules, 0);
      expect(await File('${fixture.path}/mihomo.pid').exists(), isFalse);
      expect(await config.readAsString(), 'mixed-port: 7890\n');
    }, skip: Platform.isWindows);

    test('unexpected validation exception keeps cleanup and config intact',
        () async {
      final proxy = _ControlledStopProxy();
      final core = _ThrowingValidationClashService(systemProxyService: proxy)
        ..setCorePath(validator.path)
        ..setPaths(configDir: fixture.path, configPath: config.path);
      addTearDown(core.dispose);
      expect(await core.start(), isFalse);
      expect(core.lastStartError, isNotNull);
      expect(core.isRunning, isFalse);
      expect(proxy.setCalls, 0);
      expect(proxy.clearCalls, 1);
      expect(core.recentLogs, contains('启动异常'));
      expect(await config.readAsString(), 'mixed-port: 7890\n');
      expect(await File('${config.path}.spawned').exists(), isFalse);
    });

    test('real Windows child commits exact identity before acquiring proxy',
        () async {
      final proxy = _ControlledStopProxy();
      final core = startup(proxy);
      proxy.set = () async {
        final record = WindowsCorePidRecord.tryParse(
            await File('${fixture.path}/mihomo.pid').readAsString());
        expect(record, isNotNull);
        expect(record!.canonicalExecutablePath.toLowerCase(),
            validator.path.toLowerCase());
        expect(record.pid,
            int.parse(await File('${config.path}.spawned').readAsString()));
        expect(core.isRunning, isFalse);
        return true;
      };
      expect(await core.start(), isTrue);
      expect(core.isRunning, isTrue);
      expect(proxy.setCalls, 1);
      expect(core.healthCalls, 2);
      expect(core.observationSchedules, 1);
      await core.stop();
      expect(core.isRunning, isFalse);
      expect(await File('${fixture.path}/mihomo.pid').exists(), isFalse);
      expect(await config.readAsString(), 'mixed-port: 7890\n');
    }, skip: !Platform.isWindows);

    test('real Windows proxy refusal rolls back child and durable identity',
        () async {
      final proxy = _ControlledStopProxy()
        ..lastError = 'fixture proxy refused'
        ..set = () async => false;
      final core = startup(proxy);
      expect(await core.start(), isFalse);
      expect(core.lastStartError, 'fixture proxy refused');
      expect(core.isRunning, isFalse);
      expect(proxy.setCalls, 1);
      expect(proxy.clearCalls, 1);
      expect(core.observationSchedules, 0);
      expect(await File('${fixture.path}/mihomo.pid').exists(), isFalse);
    }, skip: !Platform.isWindows);

    test('real Windows cancellation rejects a late successful proxy commit',
        () async {
      final proxy = _ControlledStopProxy();
      final core = startup(proxy);
      final entered = Completer<void>();
      final release = Completer<bool>();
      proxy.set = () {
        entered.complete();
        return release.future;
      };
      final first = core.start();
      expect(identical(first, core.start()), isTrue);
      await entered.future.timeout(const Duration(seconds: 20));
      core.requestConnectionIntent(false);
      final stopping = core.stop();
      expect(core.isRunning, isFalse);
      release.complete(true);
      expect(await first, isFalse);
      await stopping;
      expect(core.lastStartError, '连接已取消');
      expect(core.connectionDesired, isFalse);
      expect(proxy.setCalls, 1);
      expect(core.observationSchedules, 0);
      expect(await File('${fixture.path}/mihomo.pid').exists(), isFalse);
    }, skip: !Platform.isWindows);

    test('real Windows final health failure prevents connection commit',
        () async {
      final proxy = _ControlledStopProxy();
      final core = startup(proxy)..health = (call) async => call == 1;
      expect(await core.start(), isFalse);
      expect(core.lastStartError, contains('提交期间失去响应'));
      expect(core.isRunning, isFalse);
      expect(proxy.setCalls, 1);
      expect(proxy.clearCalls, 1);
      expect(core.observationSchedules, 0);
      expect(await File('${fixture.path}/mihomo.pid').exists(), isFalse);
    }, skip: !Platform.isWindows);

    test('real Windows exit cleans identity without restoring cancelled intent',
        () async {
      final proxy = _ControlledStopProxy();
      final core = startup(proxy);
      expect(await core.start(), isTrue);
      core.requestConnectionIntent(false);
      await File('${config.path}.exit').writeAsString('exit');
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (core.isRunning && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(core.isRunning, isFalse);
      expect(core.connectionDesired, isFalse);
      expect(await File('${fixture.path}/mihomo.pid').exists(), isFalse);
      expect(proxy.setCalls, 1);
      expect(core.recentLogs, contains('进程已退出，退出码: 19'));
    }, skip: !Platform.isWindows);

    test('successful validation retains a safe idle runtime', () async {
      final core = service();
      expect(await core.runConfigValidation(), isTrue);
      expect(core.lastStartError, isNull);
      expect(core.isRunning, isFalse);
      expect(core.connectionDesired, isFalse);
      expect(await config.readAsString(), 'mixed-port: 7890\n');
    });

    test('healthy runtime reuse closes timing without rerunning validation',
        () async {
      final core = _HealthyReuseLifecycleClashService(
        systemProxyService: _ControlledStopProxy(),
      )
        ..setCorePath(validator.path)
        ..setPaths(configDir: fixture.path, configPath: config.path)
        ..setRunning(true)
        ..requestConnectionIntent(true);
      addTearDown(core.dispose);
      expect(await core.start(), isTrue);
      expect(core.recentLogs, contains('outcome=localReady'));
      expect(core.recentLogs, isNot(contains('正在校验')));
      expect(core.isRunning, isTrue);
    });

    test('stderr takes precedence over stdout for an unknown failure',
        () async {
      final core = service();
      expect(
          await core.runConfigValidation({
            'SSRVPN_FIXTURE_EXIT': '1',
            'SSRVPN_FIXTURE_STDOUT': 'fixture stdout',
            'SSRVPN_FIXTURE_STDERR': 'fixture stderr',
          }),
          isFalse);
      expect(core.lastStartError, 'Mihomo 配置校验失败: fixture stderr');
    });

    test('stdout remains actionable when a failed validator has no stderr',
        () async {
      final core = service();
      expect(
          await core.runConfigValidation({
            'SSRVPN_FIXTURE_EXIT': '1',
            'SSRVPN_FIXTURE_STDOUT': 'fixture stdout',
          }),
          isFalse);
      expect(core.lastStartError, 'Mihomo 配置校验失败: fixture stdout');
    });

    test('empty failure output gets an actionable bounded fallback', () async {
      final core = service();
      expect(await core.runConfigValidation({'SSRVPN_FIXTURE_EXIT': '1'}),
          isFalse);
      expect(core.lastStartError, 'Mihomo 配置校验失败，请打开运行日志查看具体配置错误');
    });

    test('timeout outcome cannot be accepted as a successful validator',
        () async {
      final core = service();
      expect(await core.runConfigValidation({'SSRVPN_FIXTURE_EXIT': '124'}),
          isFalse);
      expect(core.lastStartError, contains('配置校验响应超时'));
      expect(core.isRunning, isFalse);
    });

    test('missing core blocks startup before any process commit', () async {
      final core = service()..setCorePath('${fixture.path}/missing-core.exe');
      expect(await core.start(), isFalse);
      expect(core.lastStartError, contains('找不到 mihomo.exe'));
      expect(core.isRunning, isFalse);
      expect(core.recentLogs, isNot(contains('Mihomo 进程已创建')));
    });

    test('missing runtime config blocks startup before validation', () async {
      final core = service()
        ..setPaths(
            configDir: fixture.path,
            configPath: '${fixture.path}/missing.yaml');
      expect(await core.start(), isFalse);
      expect(core.lastStartError, '找不到生成的 Mihomo 配置文件');
      expect(core.recentLogs, isNot(contains('正在校验')));
    });

    test('failed validation prevents core creation and preserves the config',
        () async {
      const rejected = 'mixed-port: 7890\n# fixtureExit=1\n';
      await config.writeAsString(rejected);
      final core = service()..requestConnectionIntent(true);
      expect(await core.start(), isFalse);
      expect(core.lastStartError, 'Mihomo 配置校验失败，请打开运行日志查看具体配置错误');
      expect(core.isRunning, isFalse);
      expect(core.recentLogs, isNot(contains('Mihomo 进程已创建')));
      expect(await config.readAsString(), rejected);
    });

    test('cancellation outcome propagates without becoming a config failure',
        () async {
      final core = service();
      await expectLater(
          core.runConfigValidation({'SSRVPN_FIXTURE_EXIT': '125'}),
          throwsException);
      expect(core.lastStartError, isNull);
    });

    test('missing Windows dependencies retain their specific explanation',
        () async {
      final core = service();
      expect(
          await core
              .runConfigValidation({'SSRVPN_FIXTURE_EXIT': '-1073741515'}),
          isFalse);
      expect(core.lastStartError, 'Mihomo 无法在此电脑运行: 缺少运行库或依赖 DLL');
    }, skip: !Platform.isWindows);

    test('interrupting a live validator releases startup without core commit',
        () async {
      await config.writeAsString('mixed-port: 7890\n# fixtureWait\n');
      final marker = File('${config.path}.started');
      final core = service()..requestConnectionIntent(true);
      final starting = core.start();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!await marker.exists() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await marker.exists(), isTrue);
      core.interruptPendingStart();
      expect(await starting.timeout(const Duration(seconds: 5)), isFalse);
      expect(core.lastStartError, '连接已取消');
      expect(core.isRunning, isFalse);
      expect(
          await File('${fixture.path}${Platform.pathSeparator}mihomo.pid')
              .exists(),
          isFalse);
    });
  });

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
    expect(checks, hasLength(3));
    final tun = checks.singleWhere((check) => check.id == 'tun_recovery');
    expect(tun.status, AppDiagnosticStatus.passed);
    expect(tun.summary, contains('没有待确认'));
    final proxy = checks.singleWhere((check) => check.id == 'system_proxy');
    expect(proxy.status, AppDiagnosticStatus.passed);
    expect(proxy.errorCode, isNull);
    expect(proxy.repairAction, isNull);
    final session = checks.singleWhere((check) => check.id == 'core_session');
    expect(session.status, AppDiagnosticStatus.skipped);
    expect(session.summary, contains('未获取'));
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

  test(
      'confirmed owned proxy recovery clears an old error without starting a core',
      () async {
    final proxy = _ControlledStopProxy()..recoveryPending = true;
    final service = ClashService(systemProxyService: proxy)
      ..setLastStartError('old recovery failure');
    addTearDown(service.dispose);
    expect(await service.recoverPendingSystemProxy(), isTrue);
    expect(proxy.recoveryCalls, 1);
    expect(service.lastStartError, isNull);
    expect(service.isRunning, isFalse);
    expect(service.connectionDesired, isFalse);
    expect(proxy.clearCalls, 0);
  });

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

  test('concurrent stops wait for one proxy cleanup before disconnecting',
      () async {
    final proxy = _ControlledStopProxy();
    final service = await _initializedStopService(proxy);
    service.setRunning(true);
    final started = Completer<void>();
    final release = Completer<bool>();
    proxy.clear = () {
      started.complete();
      return release.future;
    };

    final first = service.stop();
    await started.future;
    final second = service.stop();
    expect(service.isRunning, isTrue);
    expect(proxy.clearCalls, 1);
    release.complete(true);
    await Future.wait([first, second]);

    expect(proxy.clearCalls, 1);
    expect(service.isRunning, isFalse);
  });

  test('failed owned-endpoint cleanup preserves the connection until retry',
      () async {
    final proxy = _ControlledStopProxy();
    final service = await _initializedStopService(proxy);
    service
      ..requestConnectionIntent(true)
      ..setRunning(true);
    proxy
      ..recoveryPending = true
      ..lastError = '恢复被拒绝'
      ..clear = () async => false;

    await expectLater(service.stop(), throwsStateError);
    expect(service.isRunning, isTrue);
    expect(service.hasPendingSystemProxyRecovery, isTrue);

    proxy.clear = () async {
      proxy.recoveryPending = false;
      proxy.lastError = null;
      return true;
    };
    await service.stop();
    expect(service.isRunning, isFalse);
    expect(service.hasPendingSystemProxyRecovery, isFalse);
    expect(proxy.clearCalls, 2);
  });

  test('safe endpoint disconnects while journal failure remains visible',
      () async {
    final proxy = _ControlledStopProxy();
    final service = await _initializedStopService(proxy);
    service.setRunning(true);
    proxy
      ..recoveryPending = true
      ..endpointSafeWithPendingRecovery = true
      ..lastError = '恢复日志仍待清理'
      ..clear = () async => false;

    await service.stop();
    expect(service.isRunning, isFalse);
    expect(service.hasPendingSystemProxyRecovery, isTrue);
    await service.flushLogs();
    expect(await File(service.logPath).readAsString(), contains('恢复日志仍待清理'));

    proxy.clear = () async {
      proxy.recoveryPending = false;
      proxy.endpointSafeWithPendingRecovery = false;
      proxy.lastError = null;
      return true;
    };
    await service.stop();
    expect(service.hasPendingSystemProxyRecovery, isFalse);
  });

  test('unverified PID residue blocks restart and survives repeated stop',
      () async {
    final service = await _initializedStopService(_ControlledStopProxy());
    final record =
        File('${service.configDir}${Platform.pathSeparator}mihomo.pid');
    await record.writeAsString('unknown owner');
    service.setRunning(true);

    await expectLater(service.stop(), throwsStateError);
    expect(service.isRunning, isFalse);
    expect(await record.readAsString(), 'unknown owner');
    await expectLater(service.stop(), throwsStateError);
    expect(await record.readAsString(), 'unknown owner');
  });

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

  Future<bool> runConfigValidation(
          [Map<String, String> environment = const {}]) =>
      validateConfig(environment);

  Future<void> probeCoreVersion() => logCoreVersion();
}

class _HealthyReuseLifecycleClashService
    extends _InspectableLifecycleClashService {
  _HealthyReuseLifecycleClashService({required super.systemProxyService});

  @override
  Future<bool> healthCheck() async => true;
}

// Keep production spawn, identity persistence, rollback and verified termination.
// Only readiness and registry-facing proxy operations are controlled by tests.
class _StartupLifecycleClashService extends _InspectableLifecycleClashService {
  _StartupLifecycleClashService({required super.systemProxyService});

  int healthCalls = 0;
  int observationSchedules = 0;
  Future<bool> Function(int call) health = (_) async => true;

  @override
  Future<bool> healthCheck() => health(++healthCalls);

  @override
  bool get enablePeriodicHealthMonitor => false;

  @override
  Future<void> observeDataPlaneHealth() async {}

  @override
  void scheduleDataPlaneObservation({
    bool rerunIfActive = false,
    Duration delay = Duration.zero,
  }) {
    observationSchedules++;
  }
}

class _ThrowingValidationClashService
    extends _InspectableLifecycleClashService {
  _ThrowingValidationClashService({required super.systemProxyService});

  @override
  Future<bool> validateConfig(Map<String, String> environment) async =>
      throw const FileSystemException('fixture validation read failed');
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

// The lifecycle is exercised independently of registry script execution;
// system_proxy_recovery_test covers the concrete Windows transaction engine.
class _ControlledStopProxy implements SystemProxyService {
  Future<bool> Function() clear = () async => true;
  Future<bool> Function() set = () async => true;
  int clearCalls = 0;
  int setCalls = 0;
  int recoveryCalls = 0;

  @override
  bool get ownershipChangedSinceLastAcquisition => false;

  @override
  Future<SystemProxyOwnershipStatus>
      currentSystemProxyOwnershipStatus() async =>
          SystemProxyOwnershipStatus.owned;

  @override
  Future<bool> setSystemProxy(String host, int port,
      {Future<void>? cancellation}) {
    expect(host, '127.0.0.1');
    expect(port, greaterThan(0));
    setCalls++;
    return set();
  }

  @override
  Future<bool> retryPendingRecovery() async {
    recoveryCalls++;
    recoveryPending = false;
    return true;
  }

  @override
  bool recoveryPending = false;
  @override
  bool endpointSafeWithPendingRecovery = false;
  @override
  String? lastError;
  @override
  Future<void> initialize(String dataDir) async {}
  @override
  Future<bool> clearSystemProxy() {
    clearCalls++;
    return clear();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<ClashService> _initializedStopService(SystemProxyService proxy) async {
  final temp = await Directory.systemTemp.createTemp('ssrvpn_stop_fault_');
  final service = ClashService(systemProxyService: proxy);
  addTearDown(() async {
    await service.flushLogs();
    service.dispose();
    await temp.delete(recursive: true);
  });
  await service.init(AppSettings(), dataDir: temp.path, skipCoreProbes: true);
  return service;
}
