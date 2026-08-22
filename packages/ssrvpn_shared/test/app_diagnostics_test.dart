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
        AppFailure.fromMessage('文件可能被安全软件拦截或当前目录没有执行权限').code,
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

    test('maps Windows TUN failures to actionable permission guidance', () {
      for (final message in const [
        'TUN 模式需要以管理员身份运行 SSRVPN',
        '无法确认管理员权限，TUN 模式已安全中止，请重新以管理员身份运行 SSRVPN',
      ]) {
        final failure = AppFailure.fromMessage(message);

        expect(failure.code, AppErrorCode.permissionRequired);
        expect(failure.recommendedAction, '请退出 SSRVPN 后，以管理员身份重新运行。');
      }

      final listenerFailure = AppFailure.fromMessage(
        'TUN 监听未能启用，请检查管理员权限、驱动或同名虚拟网卡冲突',
      );
      expect(listenerFailure.code, AppErrorCode.permissionRequired);
      expect(listenerFailure.recommendedAction, contains('关闭其他 VPN'));
      expect(listenerFailure.recommendedAction, contains('重装官方版本'));
      expect(listenerFailure.recommendedAction, isNot(contains('退出 SSRVPN')));

      for (final message in const [
        'TUN_RUNTIME_UNAVAILABLE: Mihomo API 已就绪，但 TUN listener 未启用',
        '连接提交前的就绪检查失败：TUN_CONFIG_MISMATCH: TUN listener 未启用',
      ]) {
        final failure = AppFailure.fromMessage(message);
        expect(failure.code, AppErrorCode.permissionRequired);
        expect(failure.recommendedAction, contains('关闭其他 VPN'));
        expect(failure.recommendedAction, contains('重装官方版本'));
        expect(failure.recommendedAction, isNot(contains('TUN 驱动')));
        expect(failure.recommendedAction, isNot(contains('订阅')));
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

    test('maps stable runtime health codes and commit failures', () {
      const cases = <String, AppErrorCode>{
        'CORE_API_UNAVAILABLE: Mihomo API 不可用': AppErrorCode.coreUnavailable,
        'TUN_SERVICE_LOST: TUN 授权会话已停止响应': AppErrorCode.coreUnavailable,
        'TUN_CONFIG_MISMATCH: Mihomo API 已就绪，但 TUN listener 未启用':
            AppErrorCode.permissionRequired,
        'LOCAL_PROXY_LISTENER_UNAVAILABLE: 本地代理端口 7890 未响应':
            AppErrorCode.localProxyUnavailable,
        'LOCAL_PROXY_CONFIG_MISMATCH: 运行端口与本地代理配置不一致':
            AppErrorCode.localProxyUnavailable,
        'SYSTEM_PROXY_OWNERSHIP_LOST: 系统代理已被关闭或修改':
            AppErrorCode.systemProxyChanged,
        'SYSTEM_PROXY_OWNERSHIP_UNAVAILABLE: 系统代理所有权探针暂不可用':
            AppErrorCode.systemProxyOwnershipUnavailable,
        '连接提交前的就绪检查失败': AppErrorCode.coreUnavailable,
        'Mihomo 在连接提交期间失去响应': AppErrorCode.coreUnavailable,
        'Mihomo 在系统代理设置期间失去响应': AppErrorCode.coreUnavailable,
        'TUN 启动最终复核失败': AppErrorCode.coreUnavailable,
      };

      for (final entry in cases.entries) {
        final failure = AppFailure.fromMessage('${entry.key}; token=secret');

        expect(failure.code, entry.value, reason: entry.key);
        expect(failure.userMessage, isNot(contains('secret')));
        expect(failure.userMessage, isNot(contains(entry.key)));
      }
    });

    test('maps every stable Android core-start failure code', () {
      const cases = <String, AppErrorCode>{
        'CORE_START_PERMISSION': AppErrorCode.permissionRequired,
        'CORE_START_PORT_CONFLICT': AppErrorCode.portOccupied,
        'CORE_START_API_AUTH': AppErrorCode.coreUnavailable,
        'CORE_START_TUN': AppErrorCode.coreUnavailable,
        'CORE_START_CONFIG': AppErrorCode.configInvalid,
        'CORE_START_TIMEOUT': AppErrorCode.coreStartTimeout,
        'CORE_START_COMPONENT': AppErrorCode.coreMissing,
        'CORE_START_BUSY': AppErrorCode.coreUnavailable,
        'CORE_START_UNKNOWN': AppErrorCode.unknown,
      };

      for (final entry in cases.entries) {
        final failure = AppFailure.fromMessage(
          '${entry.key}: Android startup detail; token=secret',
        );

        expect(failure.code, entry.value, reason: entry.key);
        expect(failure.userMessage, isNot(contains('secret')));
      }
    });

    test('maps fixed desktop failures to precise actions', () {
      const cases = <({
        String message,
        AppErrorCode code,
        String actionContains,
      })>[
        (
          message: '电脑性能不足或核心启动过慢，请重新连接',
          code: AppErrorCode.coreStartTimeout,
          actionContains: '重试',
        ),
        (
          message: 'TUN 核心端口被其他程序占用，请关闭冲突程序后重试',
          code: AppErrorCode.portOccupied,
          actionContains: '自动选择可用端口',
        ),
        (
          message: '检测到上次异常退出的 TUN 会话，请重启 Mac 后重试',
          code: AppErrorCode.tunRecoveryPending,
          actionContains: '重启电脑',
        ),
        (
          message: 'TUN 网卡或路由创建失败，请重启电脑后重试',
          code: AppErrorCode.networkConflict,
          actionContains: '重启电脑',
        ),
        (
          message: '当前 Windows 账户不能直接提升为管理员；TUN 模式未启动，请使用管理员账户运行 SSRVPN',
          code: AppErrorCode.permissionRequired,
          actionContains: '管理员账户',
        ),
      ];

      for (final entry in cases) {
        final failure = AppFailure.fromMessage(entry.message);

        expect(failure.code, entry.code, reason: entry.message);
        expect(
          failure.recommendedAction,
          contains(entry.actionContains),
          reason: entry.message,
        );
        expect(failure.userMessage, isNot(contains(entry.message)));
      }
    });

    test('maps fixed macOS TUN failures to safe recovery guidance', () {
      const cases = <String, AppErrorCode>{
        '请先把 SSRVPN 拖到 Applications 文件夹，再开启 TUN 模式':
            AppErrorCode.appLocationRequired,
        '检测到其他 VPN/TUN 正在接管网络，请先断开后再连接': AppErrorCode.networkConflict,
        '检测到物理网络已切换，TUN 已安全停止，请重新连接': AppErrorCode.networkConflict,
        'TUN DNS 恢复尚未完成，已保留恢复会话': AppErrorCode.tunRecoveryPending,
        'TUN 授权会话停止超时，已保留 DNS 恢复标记': AppErrorCode.tunRecoveryPending,
      };

      for (final entry in cases.entries) {
        final failure = AppFailure.fromMessage(entry.key);
        expect(failure.code, entry.value, reason: entry.key);
        expect(failure.userMessage, isNot(contains(entry.key)));
        expect(failure.recommendedAction, isNotEmpty);
      }

      expect(
        AppFailure.fromMessage(
          '请先把 SSRVPN 拖到 Applications 文件夹，再开启 TUN 模式',
        ).recommendedAction,
        contains('Applications'),
      );
      expect(
        AppFailure.fromMessage(
          '检测到其他 VPN/TUN 正在接管网络，请先断开后再连接',
        ).recommendedAction,
        contains('断开其他 VPN'),
      );
      expect(
        AppFailure.fromMessage(
          'TUN DNS 恢复尚未完成，已保留恢复会话',
        ).recommendedAction,
        contains('再次点击连接'),
      );
    });

    test('maps fixed Windows core and TUN failures without raw passthrough',
        () {
      const cases = <String, AppErrorCode>{
        '找不到 mihomo.exe，文件可能未完整解压或被安全软件隔离': AppErrorCode.coreMissing,
        'Mihomo 与这台电脑的 Windows 架构不兼容，本版本仅支持 64 位 Windows':
            AppErrorCode.coreMissing,
        '程序或依赖 DLL 的 32/64 位架构不匹配': AppErrorCode.coreMissing,
        '无法确认旧 Windows TUN 网卡和路由已清理；为避免死路由，已安全中止':
            AppErrorCode.tunRecoveryPending,
        '核心已停止，但 Windows TUN 网卡未在超时前移除': AppErrorCode.tunRecoveryPending,
        '无法持久化 TUN 清理状态，已在启动 Mihomo 前安全中止': AppErrorCode.tunRecoveryPending,
      };

      for (final entry in cases.entries) {
        final failure = AppFailure.fromMessage('${entry.key}; token=secret');
        expect(failure.code, entry.value, reason: entry.key);
        expect(failure.userMessage, isNot(contains('secret')));
        expect(failure.userMessage, isNot(contains(entry.key)));
        expect(failure.recommendedAction, isNotEmpty);
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

    test('maps Windows installer publication failures to update guidance', () {
      final failure = AppFailure.fromMessage(
        StateError('Windows 更新安装包安全保存失败'),
      );

      expect(failure.code, AppErrorCode.updateFailed);
      expect(failure.userMessage, contains('更新失败'));
      expect(failure.userMessage, contains('稍后重试或从官网下载'));
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
            id: 'system_proxy_ownership',
            title: '系统代理所有权',
            status: AppDiagnosticStatus.warning,
            summary: '探针暂不可用，当前连接保持',
            errorCode: AppErrorCode.systemProxyOwnershipUnavailable,
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
      expect(text, contains('SYSTEM_PROXY_OWNERSHIP_UNAVAILABLE'));
      expect(text, isNot(contains('(UNKNOWN)')));
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
