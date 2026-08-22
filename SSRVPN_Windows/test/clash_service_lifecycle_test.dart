import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/services/clash_service.dart';
import 'package:ssrvpn_windows/services/system_proxy_service.dart';

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

  test('uninitialized lifecycle fails start without spawning a process',
      () async {
    final service = _createTestService();

    expect(await service.start(), isFalse);
    expect(service.lastStartError, contains('尚未初始化'));
  });

  test('automatic recovery fails safely before lifecycle initialization',
      () async {
    final service = _createTestService();

    expect(await service.startForAutomaticRecovery(), isFalse);
    expect(service.lastStartError, contains('尚未初始化'));
  });

  test('config validator execution failure keeps the actionable process error',
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
    expect(
      service.lastStartError,
      isNot(contains('配置校验失败，请打开运行日志')),
    );
    expect(
      service.lastStartError,
      anyOf(
        contains('安全软件'),
        contains('执行权限'),
        contains('架构不兼容'),
      ),
    );
    expect(
      AppFailure.fromMessage(service.lastStartError).code,
      anyOf(
        AppErrorCode.permissionRequired,
        AppErrorCode.coreMissing,
      ),
    );
    await service.flushLogs();
    final logs = await File(
      '${temp.path}${Platform.pathSeparator}ssrvpn.log',
    ).readAsString();
    expect(logs, contains('event=windows_config_validation_launch_failed'));
    expect(logs, isNot(contains('ProcessException:')));
    expect(logs, isNot(contains('Command:')));
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

  test('pending proxy recovery fails closed when its state path is unavailable',
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
  });
}

class _InspectableHealthTimeoutClashService extends ClashService {
  Duration get exposedHealthCheckTimeout => healthCheckTimeout;
}
