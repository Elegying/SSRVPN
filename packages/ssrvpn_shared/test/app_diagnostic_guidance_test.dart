import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_diagnostics.dart';
import 'package:ssrvpn_shared/widgets/app_diagnostics_view.dart';

void main() {
  AppDiagnosticCheck check(
    String id, {
    AppErrorCode? code,
    AppDiagnosticStatus status = AppDiagnosticStatus.warning,
    AppRepairAction? repair,
  }) =>
      AppDiagnosticCheck(
        id: id,
        title: id,
        status: status,
        summary: '观察 token=private-value',
        errorCode: code,
        repairAction: repair,
      );

  test('guidance preserves uncertainty, history and repair capability', () {
    final external = check('data_plane').guidance!;
    expect(external.impact, contains('不能据此认定节点损坏'));
    expect(external.nextStep, contains('若确实打不开'));
    expect(
      check('last_start', code: AppErrorCode.coreMissing).guidance!.impact,
      contains('不代表当前连接仍然失败'),
    );
    expect(
      check('ports', code: AppErrorCode.portOccupied).guidance!.nextStep,
      contains('无需处理'),
    );
    final proxy = check(
      'system_proxy',
      code: AppErrorCode.proxyRecoveryPending,
    );
    expect(proxy.guidance!.nextStep, isNot(contains('点击')));
    expect(
      check(
        'system_proxy',
        code: AppErrorCode.proxyRecoveryPending,
        repair: AppRepairAction.retryOwnedProxyRecovery,
      ).guidance!.nextStep,
      contains('点击'),
    );
    expect(
      check('core', code: AppErrorCode.coreMissing).guidance!.impact,
      contains('还是检查失败'),
    );
    expect(check('unknown').guidance, isNull);
    expect(
      check(
        'core',
        status: AppDiagnosticStatus.passed,
        code: AppErrorCode.coreMissing,
      ).guidance,
      isNull,
    );
  });

  test('empty and skipped reports never claim normal operation', () {
    for (final checks in [
      <AppDiagnosticCheck>[],
      [check('platform', status: AppDiagnosticStatus.skipped)],
    ]) {
      expect(
        AppDiagnosticReport(
          generatedAt: DateTime(2026),
          checks: checks,
        ).userConclusion,
        '尚无足够检查结果，请重新检查',
      );
    }
  });

  test('current failures lead older reminders without changing severity', () {
    final history = check('last_start', code: AppErrorCode.permissionRequired);
    final current = check('core',
        code: AppErrorCode.coreMissing, status: AppDiagnosticStatus.failed);
    final report = AppDiagnosticReport(
        generatedAt: DateTime(2026), checks: [history, current]);
    expect(report.attentionChecks, [current, history]);
    expect(report.userConclusion, contains('连接服务文件未确认可用'));
    expect(history.status, AppDiagnosticStatus.warning);
    final unchecked = AppDiagnosticReport(
        generatedAt: DateTime(2026),
        checks: [check('platform', status: AppDiagnosticStatus.skipped)],
        recentLogs: '[2026-10-05T00:00:00Z] [WARNING] [runtime] old warning');
    expect(unchecked.userConclusion, contains('尚无当前检查结果'));
  });

  test(
    'copy retains original evidence, stable code and readable next step',
    () {
      final report = AppDiagnosticReport(
        generatedAt: DateTime(2026),
        checks: [
          check(
            'system_proxy',
            code: AppErrorCode.proxyRecoveryPending,
            repair: AppRepairAction.retryOwnedProxyRecovery,
          ),
        ],
      );
      final exported = report.toText();
      expect(exported, contains('PROXY_RECOVERY_PENDING'));
      expect(exported, contains('观察'));
      expect(exported, contains('下一步：点击'));
      expect(exported, isNot(contains('private-value')));
    },
  );

  testWidgets('small large-text view prioritizes action and folds evidence', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Scaffold(
          body: AppDiagnosticsView(
            runDiagnostics: () async => AppDiagnosticReport(
              generatedAt: DateTime(2026),
              checks: [
                check('正常项目', status: AppDiagnosticStatus.passed),
                check('data_plane', code: AppErrorCode.dataPlaneDegraded),
              ],
            ),
            loadHistory: () async => [],
            repair: (_) async =>
                const AppRepairResult(success: false, message: 'unused'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('还不能确认外部网络是否可用'), findsOneWidget);
    expect(find.textContaining('下一步：'), findsOneWidget);
    expect(find.text('正常项目'), findsNothing);
    expect(find.textContaining('private-value'), findsNothing);
    expect(find.textContaining('错误编号：'), findsNothing);
    await tester.ensureVisible(find.text('技术详情'));
    await tester.tap(find.text('技术详情'));
    await tester.pumpAndSettle();
    expect(find.text('错误编号：DATA_PLANE_DEGRADED'), findsOneWidget);
    expect(find.textContaining('private-value'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
