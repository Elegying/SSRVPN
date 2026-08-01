import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';
import 'package:ssrvpn_windows/services/clash_service.dart';

void main() {
  test('fresh lifecycle reports safe idle diagnostics', () async {
    final service = ClashService();

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
    final service = ClashService();

    expect(await service.recoverPendingSystemProxy(), isTrue);
    final result = await service.repairDiagnosticIssue(
      AppRepairAction.retryOwnedProxyRecovery,
    );

    expect(result.success, isTrue);
    expect(result.message, contains('已恢复'));
  });

  test('proxy recovery repair refuses to run while connected', () async {
    final service = ClashService()..setRunning(true);

    final result = await service.repairDiagnosticIssue(
      AppRepairAction.retryOwnedProxyRecovery,
    );

    expect(result.success, isFalse);
    expect(result.message, contains('请先断开连接'));
  });

  test('startup disable reason blocks start and config writes', () async {
    final service = ClashService();
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

  test('uninitialized lifecycle fails start without spawning a process', () async {
    final service = ClashService();

    expect(await service.start(), isFalse);
    expect(service.lastStartError, 'Mihomo service is not initialized');
  });
}
