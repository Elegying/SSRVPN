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
    expect(service.lastStartError, 'Mihomo service is not initialized');
  });

  test('automatic recovery fails safely before lifecycle initialization',
      () async {
    final service = _createTestService();

    expect(await service.startForAutomaticRecovery(), isFalse);
    expect(service.lastStartError, 'Mihomo service is not initialized');
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
    addTearDown(() => temp.delete(recursive: true));
    final proxy = SystemProxyService.forTesting(
      isWindows: true,
      localAppData: '',
      scriptRunner: (_) async => ProcessResult(0, 0, '', ''),
    );
    final service = ClashService(systemProxyService: proxy);
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
