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
      final changed = AppFailure.fromMessage(
        '连接失败: 订阅已更新，请重新连接以使用最新配置',
      );
      expect(changed.code, AppErrorCode.subscriptionChanged);
      expect(changed.title, '订阅已更新');
      expect(changed.recommendedAction, contains('重新点击连接'));
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
      expect(
        AppFailure.fromMessage('Windows Mihomo 核心启动配置校验响应超时；raw-secret').code,
        AppErrorCode.coreStartTimeout,
      );
      expect(
        AppFailure.fromMessage('Windows 系统代理 PowerShell 命令响应超时；raw-secret')
            .code,
        AppErrorCode.proxyRecoveryPending,
      );
      expect(
        AppFailure.fromMessage('Windows 系统命令响应超时；raw-secret').code,
        AppErrorCode.unknown,
      );
      expect(
        AppFailure.fromMessage('客户端仍在初始化，请稍后重试').code,
        AppErrorCode.coreUnavailable,
      );
      expect(
        AppFailure.fromMessage('请先添加并刷新订阅').code,
        AppErrorCode.subscriptionFailed,
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

      final timeout = AppFailure.fromMessage(
        'Windows 系统代理 PowerShell 命令响应超时；'
        'script=C:\\private\\secret.ps1',
      );
      expect(timeout.code, AppErrorCode.proxyRecoveryPending);
      expect(timeout.userMessage, contains('系统代理待恢复'));
      expect(timeout.userMessage, isNot(contains('secret.ps1')));
    });

    test('maps Windows TUN administrator failures to relaunch guidance', () {
      for (final message in const [
        'TUN 模式需要以管理员身份运行 SSRVPN',
        '无法确认管理员权限，TUN 模式已安全中止，请重新以管理员身份运行 SSRVPN',
      ]) {
        final failure = AppFailure.fromMessage(message);

        expect(failure.code, AppErrorCode.permissionRequired);
        expect(failure.recommendedAction, '请退出 SSRVPN 后，以管理员身份重新运行。');
      }
    });

    test('maps core and data-plane details to safe actionable copy', () {
      final core = AppFailure.fromMessage(
        'Mihomo service is not initialized: token=internal-secret',
      );
      expect(core.code, AppErrorCode.coreUnavailable);
      expect(core.userMessage, contains('本地运行核心'));
      expect(core.userMessage, isNot(contains('Mihomo')));
      expect(core.userMessage, isNot(contains('internal-secret')));

      final dataPlane = AppFailure.fromMessage('TUN 数据通道验证失败');
      expect(dataPlane.code, AppErrorCode.dataPlaneDegraded);
      expect(dataPlane.userMessage, contains('当前连接仍保留'));
      expect(dataPlane.userMessage, isNot(contains('自动切换')));
    });

    test('maps concrete desktop startup failures to actionable categories', () {
      const cases = <String, AppErrorCode>{
        '找不到生成的 Mihomo 配置文件': AppErrorCode.configInvalid,
        '电脑性能不足或配置校验超时，请重新连接': AppErrorCode.coreStartTimeout,
        'Mihomo 提前退出（退出码 1）': AppErrorCode.coreUnavailable,
        'TUN 核心启动失败': AppErrorCode.coreUnavailable,
        'Mihomo 启动后未通过就绪检查：本地 API 不可用': AppErrorCode.coreUnavailable,
      };

      for (final entry in cases.entries) {
        expect(
          AppFailure.fromMessage(entry.key).code,
          entry.value,
          reason: entry.key,
        );
      }
    });

    test('maps an empty first subscription result to retry guidance', () {
      final failure = AppFailure.fromMessage(Exception('未获取到可用节点'));

      expect(failure.code, AppErrorCode.subscriptionFailed);
      expect(failure.userMessage, contains('订阅刷新失败'));
      expect(failure.userMessage, contains('检查订阅地址和网络'));
    });

    test('maps node edit validation failures to safe field guidance', () {
      for (final error in [
        const FormatException('节点备注名已存在'),
        const FormatException('服务器地址无效'),
        const FormatException('trojan 节点缺少 password'),
        const FormatException('节点名称“top-secret”属于运行时保留名称'),
        StateError('当前没有可编辑的订阅配置'),
      ]) {
        final failure = AppFailure.fromMessage(error);

        expect(failure.code, AppErrorCode.configInvalid);
        expect(failure.userMessage, contains('检查节点名称、服务器、端口和认证信息'));
        expect(failure.userMessage, isNot(contains('top-secret')));
        expect(failure.userMessage, isNot(contains('password')));
      }
    });
  });

  group('safeUserFacingFailureMessage', () {
    test('preserves only explicitly trusted product messages', () {
      for (final message in const [
        '客户端仍在初始化，请稍后重试',
        '请先添加并刷新订阅',
        '订阅已更新，请重新连接以使用最新配置',
      ]) {
        expect(safeUserFacingFailureMessage(message), message);
      }
      expect(
        safeUserFacingFailureMessage(
          StateError('无法安全断开当前连接，已阻止打开更新安装包'),
        ),
        '无法安全断开当前连接，已阻止打开更新安装包',
      );
    });

    test('never exposes an unknown tray reason', () {
      final message = safeUserFacingFailureMessage(
        'PowerShell failed secret=top-secret path=C:\\private\\secret.ps1',
      );

      expect(message, isNot(contains('top-secret')));
      expect(message, isNot(contains('secret.ps1')));
      expect(message, contains('原始敏感细节不会显示'));
    });

    test('separates a trusted failure from the follow-up action', () {
      expect(
        safeUserFacingFailureWithAction(
          '客户端仍在初始化，请稍后重试',
          '请稍后再次退出。',
        ),
        '客户端仍在初始化，请稍后重试\n请稍后再次退出。',
      );
    });

    test('subscription UI copy never echoes a credential-bearing URL', () {
      final message = safeSubscriptionFailureMessage(
        Exception(
          '所有订阅刷新失败: HttpException for '
          'https://example.com/private/subscription?token=top-secret',
        ),
      );

      expect(message, contains('订阅刷新失败'));
      expect(message, contains('检查订阅地址和网络'));
      expect(message, isNot(contains('top-secret')));
      expect(message, isNot(contains('/private/subscription')));
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
          AppDiagnosticCheck(
            id: 'hostile_url_check',
            title: '远程检查',
            status: AppDiagnosticStatus.warning,
            summary: 'request failed at '
                'https://api.example.com/customers/customer-123/status',
          ),
        ],
        recentLogs: 'fetch ss://method:password@example.com:443\n'
            'url=https://example.com/sub?token=secret-value\n'
            'probe=https://probe.example.com/private/device-456\n'
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
      expect(text, contains('https://api.example.com/***'));
      expect(text, contains('https://probe.example.com/***'));
      expect(text, isNot(contains('customer-123')));
      expect(text, isNot(contains('device-456')));
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
