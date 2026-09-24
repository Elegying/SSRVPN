import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

/// Exercises real home rendering and the service's separate warning sources.
Future<void> verifyHomeProbeNoticePolicy(
  WidgetTester tester, {
  required void Function(String?) publishExternalWarning,
  required void Function(String?) publishOwnershipWarning,
  required VoidCallback publishStopped,
  String failureTitle = '连接异常',
}) async {
  SsrvpnHomeOverview overview() =>
      tester.widget<SsrvpnHomeOverview>(find.byType(SsrvpnHomeOverview));
  Future<void> render() async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  expect(overview().isConnected, isTrue);
  expect(overview().connectionNotice, isNull);
  publishExternalWarning('外部探测未通过，实际访问情况尚未确认');
  await render();
  expect(overview().isConnected, isTrue);
  expect(overview().connectionNotice, isNull);
  expect(find.text('已连接（有提醒）'), findsNothing);

  publishOwnershipWarning('系统代理所有权暂时无法确认');
  await render();
  expect(overview().connectionNotice, '系统代理所有权暂时无法确认');
  expect(find.text('已连接（有提醒）'), findsOneWidget);
  publishExternalWarning(null);
  await render();
  expect(overview().connectionNotice, '系统代理所有权暂时无法确认');

  publishOwnershipWarning(null);
  publishExternalWarning('外部探测再次未通过');
  await render();
  expect(overview().connectionNotice, isNull);
  publishStopped();
  await render();
  expect(overview().isConnected, isFalse);
  expect(overview().isConnecting, isFalse);
  expect(find.textContaining(failureTitle), findsOneWidget);
  expect(find.textContaining('连接服务已停止'), findsWidgets);
}
