import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/models/app_diagnostics.dart';
import 'package:ssrvpn_shared/services/clash_service_base.dart';
import 'package:ssrvpn_shared/widgets/ssrvpn_site_diagnostic.dart';

class _Core extends ClashServiceBase {
  bool connected = false;
  Completer<String?>? pendingSelection;
  @override
  bool get isRunning => connected;
  @override
  Future<String?> currentSelectedProxyName() async =>
      pendingSelection?.future ?? 'node';
  @override
  Future<void> onStopRequired() async {}
  @override
  Future<bool> diagnosticCoreAvailable() async => false;
  @override
  String get diagnosticConfigPath => '';
  @override
  bool get diagnosticConfigRequired => false;
  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() async => [];
  @override
  Future<AppRepairResult> repairDiagnosticIssue(AppRepairAction action) async =>
      const AppRepairResult(success: false, message: '未连接');
}

Future<void> _open(WidgetTester tester, _Core core) async {
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(body: Builder(builder: (context) {
      return TextButton(
        onPressed: () => showSsrvpnSiteDiagnostic(context, core),
        child: const Text('诊断'),
      );
    })),
  ));
  await tester.tap(find.text('诊断'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('invalid and disconnected targets leave the dialog usable',
      (tester) async {
    final core = _Core();
    await _open(tester, core);
    final input = find.byKey(const Key('ssrvpn-site-diagnostic-input'));
    await tester.enterText(input, 'https://127.0.0.1/private');
    await tester.tap(find.text('开始诊断'));
    await tester.pumpAndSettle();
    expect(find.text('请使用公开网站域名，不支持本机或 IP 地址'), findsOneWidget);
    await tester.enterText(input, 'example.com');
    await tester.tap(find.text('开始诊断'));
    await tester.pumpAndSettle();
    expect(find.text('请先连接节点，等待节点切换完成后再诊断'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('开始诊断'), findsNothing);
    expect(core.connectionDesired, isFalse);
    core.dispose();
  });

  for (final action in ['取消诊断', '关闭', 'background']) {
    testWidgets('$action invalidates a pending connection lookup',
        (tester) async {
      final core = _Core()
        ..connected = true
        ..pendingSelection = Completer<String?>();
      core.requestConnectionIntent(true);
      await _open(tester, core);
      await tester.enterText(
          find.byKey(const Key('ssrvpn-site-diagnostic-input')), 'example.com');
      await tester.tap(find.text('开始诊断'));
      await tester.pump();
      expect(find.text('取消诊断'), findsOneWidget);
      if (action == 'background') {
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
      } else {
        await tester.tap(find.text(action));
      }
      await tester.pump();
      core.pendingSelection!.complete('node');
      await tester.pumpAndSettle();
      if (action == '取消诊断') {
        expect(find.text('诊断已取消'), findsOneWidget);
      } else if (action == 'background') {
        expect(find.text('连接状态已变化，请重新诊断'), findsOneWidget);
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
      } else {
        expect(find.text('开始诊断'), findsNothing);
      }
      expect(core.connectionDesired, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      core.dispose();
    });
  }
}
