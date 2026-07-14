import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  group('AppFailure.fromMessage', () {
    test('maps common failures to stable actionable codes', () {
      expect(
        AppFailure.fromMessage('bind: address already in use').code,
        AppErrorCode.portOccupied,
      );
      expect(
        AppFailure.fromMessage('Access is denied; administrator required').code,
        AppErrorCode.permissionRequired,
      );
      expect(
        AppFailure.fromMessage('系统代理恢复失败，请重试').code,
        AppErrorCode.proxyRecoveryPending,
      );
      expect(
        AppFailure.fromMessage('Mihomo 核心文件不存在').code,
        AppErrorCode.coreMissing,
      );
      expect(
        AppFailure.fromMessage('配置验证失败: invalid yaml').code,
        AppErrorCode.configInvalid,
      );
      expect(
        AppFailure.fromMessage('部分订阅刷新失败').code,
        AppErrorCode.subscriptionPartial,
      );
      expect(
        AppFailure.fromMessage('download update failed').code,
        AppErrorCode.updateFailed,
      );
      expect(
        AppFailure.fromMessage('core startup timeout').code,
        AppErrorCode.coreStartTimeout,
      );
      expect(
        AppFailure.fromMessage('network request timed out').code,
        AppErrorCode.unknown,
      );
    });

    test('unknown failures do not expose raw internal details', () {
      final failure = AppFailure.fromMessage(
        'unexpected secret=top-secret stack=/Users/me/private.dart:12',
      );

      expect(failure.code, AppErrorCode.unknown);
      expect(failure.message, isNot(contains('top-secret')));
      expect(failure.message, isNot(contains('/Users/me')));
      expect(failure.recommendedAction, isNotEmpty);
    });
  });

  group('AppDiagnosticReport', () {
    test('exports bounded redacted text with stable check codes', () {
      final report = AppDiagnosticReport(
        generatedAt: DateTime.utc(2026, 7, 14, 12, 30),
        checks: const [
          AppDiagnosticCheck(
            id: 'core_asset',
            title: '核心文件',
            status: AppDiagnosticStatus.passed,
            summary: '核心文件完整',
          ),
          AppDiagnosticCheck(
            id: 'system_proxy',
            title: '系统代理',
            status: AppDiagnosticStatus.failed,
            summary: '系统代理恢复失败',
            errorCode: AppErrorCode.proxyRecoveryPending,
            repairAction: AppRepairAction.retryOwnedProxyRecovery,
          ),
          AppDiagnosticCheck(
            id: 'hostile_platform_check',
            title: 'secret=platform-title-secret',
            status: AppDiagnosticStatus.warning,
            summary: 'trojan://user:platform-password@example.com:443',
          ),
        ],
        recentLogs: 'fetch ss://method:password@example.com:443\n'
            'url=https://example.com/sub?token=secret-value\n'
            '${'x' * 12000}',
      );

      final text = report.toText(maxLength: 4096);

      expect(text.length, lessThanOrEqualTo(4096));
      expect(text, contains('2026-07-14T12:30:00.000Z'));
      expect(text, contains('PROXY_RECOVERY_PENDING'));
      expect(text, isNot(contains('password')));
      expect(text, isNot(contains('secret-value')));
      expect(text, isNot(contains('platform-title-secret')));
      expect(text, isNot(contains('platform-password')));
      expect(report.hasFailures, isTrue);
    });

    test('rejects invalid export bounds', () {
      final report = AppDiagnosticReport(
        generatedAt: DateTime.utc(2026),
        checks: const [],
      );

      expect(() => report.toText(maxLength: 0), throwsArgumentError);
    });
  });
}
