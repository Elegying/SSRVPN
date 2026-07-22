import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_diagnostics.dart';
import 'package:ssrvpn_shared/widgets/app_diagnostics_view.dart';

void main() {
  testWidgets('shows stable codes and runs only the offered repair',
      (tester) async {
    var runs = 0;
    var repairs = 0;
    String? message;

    Future<AppDiagnosticReport> diagnose() async {
      runs++;
      return AppDiagnosticReport(
        generatedAt: DateTime.utc(2026, 7, 14),
        checks: [
          const AppDiagnosticCheck(
            id: 'core',
            title: '运行核心',
            status: AppDiagnosticStatus.passed,
            summary: '核心文件可用',
          ),
          AppDiagnosticCheck(
            id: 'proxy',
            title: '系统代理恢复',
            status: repairs == 0
                ? AppDiagnosticStatus.warning
                : AppDiagnosticStatus.passed,
            summary: repairs == 0 ? '存在待恢复状态' : '状态已恢复',
            errorCode: repairs == 0 ? AppErrorCode.proxyRecoveryPending : null,
            repairAction:
                repairs == 0 ? AppRepairAction.retryOwnedProxyRecovery : null,
          ),
        ],
        recentLogs: 'sanitized log',
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppDiagnosticsView(
            runDiagnostics: diagnose,
            repair: (action) async {
              expect(action, AppRepairAction.retryOwnedProxyRecovery);
              repairs++;
              return const AppRepairResult(
                success: true,
                message: '代理状态已恢复',
              );
            },
            onMessage: (value) => message = value,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('PROXY_RECOVERY_PENDING'), findsOneWidget);
    expect(find.text('修复系统代理'), findsOneWidget);
    expect(find.bySemanticsLabel('重新运行诊断'), findsOneWidget);

    await tester.tap(find.text('修复系统代理'));
    await tester.pumpAndSettle();

    expect(repairs, 1);
    expect(runs, 2);
    expect(message, '代理状态已恢复');
    expect(find.text('修复系统代理'), findsNothing);
  });

  testWidgets('contains unexpected diagnostic exceptions', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppDiagnosticsView(
          runDiagnostics: () async => throw StateError('private detail'),
          repair: (_) async => const AppRepairResult(
            success: false,
            message: 'unused',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('诊断未能完成'), findsOneWidget);
    expect(find.textContaining('private detail'), findsNothing);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('diagnostic summary stays usable in compact maximum text scale',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(268, 318));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(3.2),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: AppDiagnosticsView(
            runDiagnostics: () async => AppDiagnosticReport(
              generatedAt: DateTime.utc(2026, 7, 22),
              checks: const [
                AppDiagnosticCheck(
                  id: 'core',
                  title: '运行核心',
                  status: AppDiagnosticStatus.failed,
                  summary: '核心文件不可用',
                ),
                AppDiagnosticCheck(
                  id: 'proxy',
                  title: '系统代理',
                  status: AppDiagnosticStatus.failed,
                  summary: '代理状态待恢复',
                ),
              ],
            ),
            repair: (_) async => const AppRepairResult(
              success: false,
              message: 'unused',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('发现 2 项需要处理的问题'), findsOneWidget);
    expect(find.bySemanticsLabel('复制脱敏诊断报告'), findsOneWidget);
    expect(find.bySemanticsLabel('重新运行诊断'), findsOneWidget);
  });
}
