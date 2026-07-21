import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_windows/services/windows_dpapi_secret_store.dart';
import 'package:ssrvpn_windows/startup/startup_status.dart';

void main() {
  test('unreadable DPAPI secret produces an actionable safe startup message',
      () {
    final failure = StartupFailure(
      step: 'mihomo_core',
      error: WindowsApiSecretRecoveryRequired(
        r'C:\Users\test\AppData\Local\SSRVPN\ssrvpn\.api-secret.dpapi',
      ),
    );

    expect(failure.requiresWindowsSecretRecovery, isTrue);
    expect(failure.message, contains('WINDOWS_DPAPI_RECOVERY_REQUIRED'));
    expect(failure.userSummary, contains('保留旧密文'));
    expect(failure.userSummary, contains('重建'));
    expect(failure.userSummary, contains('.api-secret.dpapi'));
    expect(
      failure.userSummary,
      contains(r'C:\Users\test\AppData\Local\SSRVPN\ssrvpn'),
    );
    expect(failure.userSummary, isNot(contains('查看诊断日志')));
  });
}
