import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ssrvpn_shared/ssrvpn_shared.dart';

void main() {
  for (final periodicHealth in [true, false]) {
    testWidgets('successful path stops background probes: $periodicHealth',
        (tester) async {
      final service = _ObservationService(periodicHealth: periodicHealth)
        ..requestConnectionIntent(true)
        ..setRunning(true);
      addTearDown(service.dispose);
      service.observe();
      await tester.pump();
      final checkedAt = service.networkVerification.checkedAt;
      expect(service.requests, 1);
      expect(service.networkVerification.label, '已连接');
      expect(service.recentLogs, contains('外部网络验证通过'));
      expect(service.recentLogs, contains('耗时='));
      expect(service.recentLogs, contains('结果=HTTP_204'));
      expect(service.recentLogs,
          matches(r'\[\d{4}-\d{2}-\d{2}T[^\]]+\] \[INFO\]'));

      service.startStatusMonitor();
      await tester.pump(const Duration(hours: 2));
      service.stopStatusMonitor();
      expect(service.requests, 1);
      expect(service.networkVerification.checkedAt, checkedAt);
      expect(service.networkVerification.label, '已连接');
      expect(service.healthChecks, periodicHealth ? greaterThan(0) : 0);
      expect(service.isRunning, isTrue);
      expect(service.connectionDesired, isTrue);
    });
  }

  testWidgets('route, network and replacement session rearm one observation',
      (tester) async {
    final service = _ObservationService()
      ..requestConnectionIntent(true)
      ..setRunning(true);
    addTearDown(service.dispose);
    service.observe();
    await tester.pump();
    expect(service.requests, 1);
    service.changeRoute();
    await tester.pump();
    expect(service.requests, 2);
    await service.runNetworkChangeCheck();
    service.fingerprint = 'mobile:198.51.100.1';
    await service.runNetworkChangeCheck();
    await tester.pump();
    expect(service.requests, 3);

    service.setRunning(true, newSession: true);
    expect(service.networkVerification.state, NetworkVerificationState.pending);
    service.observe();
    await tester.pump();
    expect(service.requests, 4);
    service.setRunning(false);
    service.observe();
    await tester.pump();
    expect(service.requests, 4);
    service.setRunning(true);
    service.observe();
    await tester.pump();
    expect(service.requests, 5);
    service.observe();
    await tester.pump();
    expect(service.requests, 5);
  });

  testWidgets('failed observation retries until success without restarting VPN',
      (tester) async {
    final service = _ObservationService(periodicHealth: false)
      ..requestConnectionIntent(true)
      ..setRunning(true)
      ..statusCode = 503;
    addTearDown(service.dispose);
    service.observe();
    await tester.pump();
    expect(
        service.networkVerification.state, NetworkVerificationState.unverified);
    service.statusCode = 204;
    service.startStatusMonitor();
    await tester.pump(const Duration(seconds: 61));
    expect(service.requests, 2);
    expect(service.networkVerification.label, '已连接');
    await tester.pump(const Duration(hours: 2));
    service.stopStatusMonitor();
    expect(service.requests, 2);
    expect(service.isRunning, isTrue);
    expect(service.connectionDesired, isTrue);
    expect(service.stopCalls, 0);
  });

  testWidgets('explicit refresh survives success and coalesces active requests',
      (tester) async {
    final service = _ObservationService()
      ..requestConnectionIntent(true)
      ..setRunning(true)
      ..deferResponses = true;
    addTearDown(service.dispose);
    service.observe();
    await tester.pump();
    service.observe(explicit: true);
    service.observe(explicit: true);
    expect(service.requests, 1);
    service.responses[0].complete(http.Response('', 204));
    await tester.pump();
    expect(service.requests, 2);
    service.responses[1].complete(http.Response('', 204));
    await tester.pump();
    service.observe();
    await tester.pump();
    expect(service.requests, 2);
    service.observe(explicit: true);
    await tester.pump();
    expect(service.requests, 3);
    service.responses[2].complete(http.Response('', 204));
    await tester.pump();
  });

  testWidgets('late old success cannot suppress retries of the new route',
      (tester) async {
    final service = _ObservationService()
      ..requestConnectionIntent(true)
      ..setRunning(true)
      ..deferResponses = true;
    addTearDown(service.dispose);
    service.observe();
    await tester.pump();
    service.changeRoute();
    await tester.pump();
    service.responses[1].complete(http.Response('', 503));
    await tester.pump();
    service.responses[0].complete(http.Response('', 204));
    await tester.pump();
    expect(
        service.networkVerification.state, NetworkVerificationState.unverified);
    expect(service.networkVerification.errorCode, 'HTTP_503');
    service.deferResponses = false;
    service.observe();
    await tester.pump();
    expect(service.requests, 3);
    expect(service.networkVerification.label, '已连接');
  });
}

class _ObservationService extends ClashServiceBase {
  _ObservationService({this.periodicHealth = true});
  final bool periodicHealth;
  int requests = 0, healthChecks = 0, stopCalls = 0, statusCode = 204;
  bool deferResponses = false;
  String fingerprint = 'wifi:192.0.2.1';
  final responses = <Completer<http.Response>>[];

  void observe({bool explicit = false}) =>
      scheduleDataPlaneObservation(rerunIfActive: explicit);
  void changeRoute() => onDataPlaneRouteChanged();
  @override
  bool get enablePeriodicHealthMonitor => periodicHealth;
  @override
  Duration? get networkChangeWatchInterval => null;
  @override
  Future<String?> buildNetworkFingerprint() async => fingerprint;
  @override
  Future<bool> healthCheck() async {
    healthChecks++;
    return true;
  }

  @override
  Future<void> observeDataPlaneHealth() async {
    await verifyUserConnectivity(
        maxAttempts: 1,
        retryDelay: Duration.zero,
        request: (_) async {
          requests++;
          if (!deferResponses) return http.Response('', statusCode);
          final response = Completer<http.Response>();
          responses.add(response);
          return response.future;
        });
  }

  @override
  Future<void> refreshRuleProvidersOnce() async {}
  @override
  Future<void> onStopRequired() async => stopCalls++;
  @override
  Future<bool> diagnosticCoreAvailable() async => true;
  @override
  String get diagnosticConfigPath => '';
  @override
  bool get diagnosticConfigRequired => false;
  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() async => const [];
  @override
  Future<AppRepairResult> repairDiagnosticIssue(AppRepairAction action) async =>
      const AppRepairResult(
          success: false, message: 'No repair in this fixture');
}
